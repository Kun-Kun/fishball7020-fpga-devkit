function tbl = fm_stations(varargin)
%FM_STATIONS  Find real broadcast FM stations, by their 19 kHz stereo pilot.
%
%   >> fm_stations                       % the whole band on RX1
%   >> fm_stations('RxChannel', 2)
%   >> fm_stations('Start', 95e6, 'Stop', 100e6, 'Step', 100e3)
%
% Receive only. Takes a minute or two for the full band.
%
% WHY NOT JUST LOOK FOR POWER. A coarse power scan tells you where energy is,
% not where a STATION is, and on this board it actively misleads: a scan
% stepping in 1.9 MHz chunks reported "96.0 MHz" as the strongest signal, and
% 96.0 MHz turned out to have no station on it at all - the number was just the
% loudest bin inside a wide step. Tuning there and hearing noise is a confusing
% way to spend an evening.
%
% A 19 kHz pilot is different: it is a narrow, exactly-placed tone that only a
% stereo FM broadcast produces. Finding one is proof. This demodulates each
% candidate and measures how far the pilot stands above the noise, which is
% slower than a power scan and tells you something a power scan cannot.

    p = inputParser;
    p.addParameter('Start', 87.5e6, @isnumeric);
    p.addParameter('Stop', 108e6, @isnumeric);
    p.addParameter('Step', 200e3, @isnumeric);
    p.addParameter('RxChannel', 1, @(v) any(v == [1 2]));
    p.addParameter('SampleRate', 2.4e6, @isnumeric);
    p.addParameter('OffsetHz', 400e3, @isnumeric);
    p.addParameter('Gain', 65, @isnumeric);
    p.addParameter('Threshold', 15, @isnumeric);   % dB above the noise floor
    p.parse(varargin{:});
    r = p.Results;

    freqs = r.Start:r.Step:r.Stop;
    fprintf('\n  scanning %.1f-%.1f MHz in %.0f kHz steps, RX%d\n', ...
            r.Start/1e6, r.Stop/1e6, r.Step/1e3, r.RxChannel);
    fprintf('  looking for a 19 kHz stereo pilot at least %g dB up\n\n', r.Threshold);

    mhz = []; pil = [];
    for fc = freqs
        d = pilotStrength(fc, r);
        if d > r.Threshold
            mhz(end+1,1) = fc/1e6; pil(end+1,1) = d; %#ok<AGROW>
            fprintf('  %7.2f MHz   pilot +%.1f dB\n', fc/1e6, d);
        end
    end

    if isempty(mhz)
        fprintf(['  nothing found. Check the antenna is on RX%d, and that the ' ...
                 'gain suits it -\n  %g dB is right for a whip on a normal ' ...
                 'band; a very strong local\n  transmitter may need less.\n'], ...
                r.RxChannel, r.Gain);
        tbl = table();
        return
    end

    [pil, ix] = sort(pil, 'descend'); mhz = mhz(ix);
    tbl = table(mhz, pil, 'VariableNames', {'MHz','PilotDb'});
    fprintf('\n  %d station(s). Strongest: %.2f MHz\n', numel(mhz), mhz(1));
    fprintf('  >> fm_receiver(''Listen'',true,''RxChannel'',%d,''CenterFrequency'',%ge6)\n\n', ...
            r.RxChannel, mhz(1));
    if nargout == 0, disp(tbl); clear tbl, end
end

function d = pilotStrength(fc, r)
    d = -Inf;
    try
        x = fishball.capture2('CenterFrequency', fc - r.OffsetHz, ...
                              'SampleRate', r.SampleRate, 'Seconds', 0.12, ...
                              'GainMode', 'manual', 'Gain', r.Gain, ...
                              'Bandwidth', 400e3);
    catch
        return
    end
    v = double(x(:, r.RxChannel));
    t = (0:numel(v)-1).'/r.SampleRate;
    v = v .* exp(-1j*2*pi*r.OffsetHz*t);      % station to DC
    dec = 10; n = floor(numel(v)/dec)*dec;
    xi = mean(reshape(v(1:n), dec, []), 1).';
    fsIf = r.SampleRate/dec;
    disc = angle(xi(2:end).*conj(xi(1:end-1)));
    N = 2^14;
    if numel(disc) < N, return, end
    D = 20*log10(abs(fft(disc(1:N).*hann(N))) + 1e-12); D = D(1:N/2);
    f = (0:N/2-1)*fsIf/N;
    nf = median(D(f > 70e3 & f < 110e3));
    d = max(D(f >= 18.9e3 & f <= 19.1e3)) - nf;
end
