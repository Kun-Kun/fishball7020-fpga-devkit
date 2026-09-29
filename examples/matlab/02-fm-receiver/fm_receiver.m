function [audio, fsAudio] = fm_receiver(varargin)
%FM_RECEIVER  Wideband FM to audio, and why you cannot ask this chip for 240 kS/s.
%
%   >> fm_receiver('CenterFrequency', 100.5e6)    % a station near you
%   >> fm_receiver('Source', 'synthetic')         % no radio needed - self-test
%   >> fm_receiver('Source', 'capture.sigmf-meta')
%   >> [a, fs] = fm_receiver(...); sound(a, fs)
%
% Receive only. Nothing here transmits.
%
% THE RATE TRAP, WHICH IS THE POINT OF THIS EXAMPLE. Broadcast FM wants about
% 200 kHz of bandwidth and every tutorial therefore tunes a Pluto to something
% like 240 kS/s. Ask THIS chip for that and the driver refuses: the AD9361
% cannot go below 2.083 MSPS with its own FIR bypassed - 25 MHz minimum ADC
% clock divided by a maximum divider of 12. Below that you must load and enable
% its internal FIR, and if you do not, the write fails and the rate stays where
% it was while your demodulator carries on believing otherwise. Symptom: a
% perfectly good waterfall and static in the speaker.
%
% So this captures at a rate the chip will actually give and decimates in
% MATLAB, which costs nothing and cannot silently be wrong.
%
% THE CHAIN
%   capture at >= 2.083 MSPS      the chip's floor, bypassed FIR
%   decimate to ~240 kHz          now we are in FM territory
%   discriminator                 angle(x[n] * conj(x[n-1])) - the frequency IS
%                                 the phase difference between samples
%   de-emphasis                   50 us in Europe, 75 us in the Americas
%   decimate to 48 kHz            audio
%
% The discriminator is written out rather than called from a toolbox because it
% is three lines and seeing them is worth more than not seeing them.

    p = inputParser;
    p.addParameter('Source', 'radio', @(s) ischar(s) || isstring(s));
    p.addParameter('CenterFrequency', 100e6, @isnumeric);
    p.addParameter('SampleRate', 2.4e6, @isnumeric);
    p.addParameter('Seconds', 2, @isnumeric);
    p.addParameter('Gain', 60, @isnumeric);
    p.addParameter('RxChannel', 1, @(v) any(v == [1 2]));
    p.addParameter('Deemphasis', 50e-6, @isnumeric);   % 75e-6 in the Americas
    p.addParameter('AudioRate', 48e3, @isnumeric);
    p.addParameter('Plot', true, @islogical);
    p.addParameter('Play', false, @islogical);
    p.parse(varargin{:});
    r = p.Results;
    src = char(r.Source);

    %% 1 - get IQ from somewhere
    switch lower(src)
        case 'radio'
            if r.SampleRate < 2.083e6
                error('fishball:fm:rateTooLow', ...
                    ['%.3f MSPS is below the AD9361''s floor of 2.083 MSPS ' ...
                     'with its FIR bypassed.\nThat write fails and the rate ' ...
                     'silently stays where it was - which is exactly the ' ...
                     'bug\nthis example exists to avoid. Use 2.4e6 and let ' ...
                     'the decimation below do the rest.'], r.SampleRate/1e6);
            end
            [x, fs] = fromRadio(r);
        case 'synthetic'
            [x, fs] = synthetic(r);
        otherwise
            [x, meta] = fishball.readSigMF(src);
            fs = meta.SampleRate;
            if size(x,2) > 1, x = x(:, min(r.RxChannel, size(x,2))); end
            fprintf('  read %d samples at %.3f MSPS from %s\n', ...
                    numel(x), fs/1e6, src);
    end
    x = double(x(:));

    %% 2 - down to FM rates
    targetIf = 240e3;
    d1 = max(1, floor(fs / targetIf));
    xi = decimateCIC(x, d1);
    fsIf = fs / d1;

    %% 3 - the discriminator. The instantaneous frequency of a complex signal
    %      IS the phase advance between consecutive samples; FM put the audio
    %      there, so taking it back out is one line.
    d = xi(2:end) .* conj(xi(1:end-1));
    disc = angle(d);                         % radians per sample
    disc = disc * fsIf / (2*pi);             % ... as Hz

    %% 4 - de-emphasis. Broadcast FM pre-emphasises treble before transmission
    %      to improve SNR; undoing it is a one-pole low pass, and skipping it
    %      is why naive FM receivers sound thin and hissy.
    alpha = exp(-1 / (fsIf * r.Deemphasis));
    de = filter(1 - alpha, [1, -alpha], disc);

    %% 5 - down to audio
    d2 = max(1, floor(fsIf / r.AudioRate));
    audio = decimateCIC(de, d2);
    fsAudio = fsIf / d2;
    if max(abs(audio)) > 0
        audio = audio / max(abs(audio)) * 0.9;
    end

    %% 6 - what happened
    fprintf('\n== chain ==\n');
    fprintf('  captured      %8.3f MSPS   %d samples\n', fs/1e6, numel(x));
    fprintf('  IF            %8.3f kHz    (decimated by %d)\n', fsIf/1e3, d1);
    fprintf('  audio         %8.3f kHz    (decimated by %d)\n', fsAudio/1e3, d2);
    fprintf('  deviation     %8.1f kHz rms (75 kHz is full modulation)\n', ...
            rms(disc)/1e3);

    if r.Plot, plotIt(x, fs, audio, fsAudio, r); end
    if r.Play && fsAudio > 7e3, sound(audio, fsAudio); end
    if nargout == 0, clear audio fsAudio, end
end

% ---------------------------------------------------------------- sources
function [x, fs] = fromRadio(r)
    if r.RxChannel == 1
        rx = fishball.connect('CenterFrequency', r.CenterFrequency, ...
                              'BasebandSampleRate', r.SampleRate, ...
                              'SamplesPerFrame', round(r.SampleRate*r.Seconds), ...
                              'Gain', r.Gain);
        cl = onCleanup(@() release(rx)); %#ok<NASGU>
        rx(); x = double(rx());
    else
        both = fishball.capture2('CenterFrequency', r.CenterFrequency, ...
                                 'SampleRate', r.SampleRate, ...
                                 'Seconds', r.Seconds, 'Gain', r.Gain);
        x = both(:,2);
    end
    fs = r.SampleRate;
end

function [x, fs] = synthetic(r)
% A known FM signal, so the chain can be checked with no radio and no antenna.
% 440 Hz tone, 75 kHz peak deviation - full modulation for broadcast FM.
    fs = r.SampleRate;
    n = round(fs * min(r.Seconds, 1));
    t = (0:n-1).' / fs;
    fm = 440; dev = 75e3;
    % phase = 2*pi*INTEGRAL(f dt). For f(t) = dev*cos(2*pi*fm*t) the integral
    % is dev*sin(2*pi*fm*t)/(2*pi*fm), so the 2*pi cancels and the modulation
    % index is dev/fm. Writing 2*pi*dev/fm here instead - which is the obvious
    % slip - makes the real deviation 2*pi times too big, 471 kHz rather than
    % 75 kHz, which promptly aliases inside the 240 kHz IF and hands the
    % demodulator nonsense. It recovered 4839.84 Hz for a 440 Hz tone: exactly
    % 11x, which is what sent me looking here rather than at the discriminator.
    phase = (dev/fm) * sin(2*pi*fm*t);
    x = exp(1j*phase);
    x = x + 0.001*(randn(n,1) + 1j*randn(n,1)); % a little noise, for realism
    fprintf('  synthetic: 440 Hz tone at 75 kHz deviation, %.3f MSPS\n', fs/1e6);
end

% ---------------------------------------------------------------- helpers
function y = decimateCIC(x, d)
% Moving-average then take every dth sample. A boxcar is a poor anti-alias
% filter and a good teaching one: it is obviously a filter, it has no design
% parameters to get wrong, and it needs no toolbox. Signal Processing Toolbox's
% decimate() is better and is the thing to reach for in real work.
    if d <= 1, y = x(:); return, end
    n = floor(numel(x)/d)*d;
    y = mean(reshape(x(1:n), d, []), 1).';
end

function plotIt(x, fs, audio, fsAudio, r)
    fig = findobj('Type','figure','Tag','fishball_fm');
    if isempty(fig), fig = figure('Tag','fishball_fm','Color','w');
    else, fig = fig(1); clf(fig); end
    set(fig,'Name','FM receiver');

    ax1 = subplot(2,1,1,'Parent',fig);
    [db, f] = fishball.spectrum(x(1:min(end,65536)), fs, 'FullScale', 2047);
    plot(ax1, (r.CenterFrequency + f)/1e6, db); grid(ax1,'on');
    xlabel(ax1,'MHz'); ylabel(ax1,'dBFS'); title(ax1,'what came off the air');

    ax2 = subplot(2,1,2,'Parent',fig);
    tA = (0:numel(audio)-1)/fsAudio;
    plot(ax2, tA, audio); grid(ax2,'on');
    xlabel(ax2,'seconds'); ylabel(ax2,'audio'); ylim(ax2,[-1 1]);
    title(ax2, sprintf('demodulated, %.1f kHz', fsAudio/1e3));
end
