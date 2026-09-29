function [x, info] = capture2(varargin)
%CAPTURE2  Both receivers at once, coherently. The thing a Pluto cannot do.
%
%   X = FISHBALL.CAPTURE2('CenterFrequency',900e6,'SampleRate',3e6,'Seconds',0.2)
%
%   X    N-by-2 complex, column 1 = RX1, column 2 = RX2, raw converter counts
%        (full scale +/-2047). Both columns come from the same buffer, so they
%        are sample-aligned by construction.
%
% WHY THIS DOES NOT USE sdrrx. The ADALM-Pluto support package is written for a
% 1R1T radio and enforces it: setting ChannelMapping to [1 2] fails with
% "Expected ChannelMapping to be a scalar", and asking for channel 2 fails with
% "ChannelMapping must be equal to 1". This board is 2R2T - cf-ad9361-lpc has
% four scan channels, I and Q for each receiver - so the two receivers are
% reachable, just not through that object. This shells out to iio_readdev,
% which has no such opinion.
%
% WHY THE TWO CHANNELS ARE WORTH THE TROUBLE. RX1 and RX2 sit inside one AD9361
% behind ONE local oscillator and ONE sample clock. The phase between them is
% therefore a property of the signal and the cabling, not of two clocks drifting
% apart - which is what makes direction finding and MIMO possible here and not
% on a one-channel radio. See fishball.phase.
%
% RATE CEILING, AND IT IS NOT ADVISORY. Two channels are clean to about 3 MS/s
% over Ethernet and drop samples at 10 MS/s (docs/capturing-iq.md). iio_readdev
% returns the byte count you asked for whether or not the DMA overflowed, so an
% over-rate capture looks perfect and is not. This function warns above 4 MS/s
% rather than silently handing you a corrupted coherence measurement.

    p = inputParser;
    p.addParameter('URI', '', @(s) ischar(s) || isstring(s));
    p.addParameter('CenterFrequency', 900e6, @isnumeric);
    p.addParameter('SampleRate', 3e6, @isnumeric);
    p.addParameter('Seconds', 0.2, @isnumeric);
    p.addParameter('Gain', 40, @isnumeric);
    p.addParameter('GainMode', 'manual', @(s) ischar(s) || isstring(s));
    p.parse(varargin{:});
    r = p.Results;

    u = fishball.uri(r.URI);
    for t = {'iio_attr','iio_readdev'}
        if isempty(fishball.internal.which_(t{1}))
            error('fishball:capture2:noTools', ...
                  ['%s is not installed.\n    sudo apt install libiio-utils'], t{1});
        end
    end

    if r.SampleRate > 4e6
        warning('fishball:capture2:rateTooHigh', ...
            ['%.1f MS/s on TWO channels drops samples on this board - ' ...
             'measured clean at 3 MS/s\nand dropping at 10. iio_readdev ' ...
             'will still return every byte you asked for, so the\nresult ' ...
             'will look fine. Use 3e6 unless you have checked yours.'], ...
            r.SampleRate/1e6);
    end

    nsamp = max(1024, round(r.SampleRate * r.Seconds));

    % Configure. Written first, then read back - the AD9361 quantises gain to
    % its own table and snaps the sample rate to what the clock tree can make,
    % so what you asked for is an intention and what comes back is a fact.
    set_(u, 'ad9361-phy',   'voltage0',    'sampling_frequency', r.SampleRate, false);
    set_(u, 'cf-ad9361-lpc','voltage0',    'sampling_frequency', r.SampleRate, false);
    set_(u, 'ad9361-phy',   'altvoltage0', 'frequency',   r.CenterFrequency, true);
    set_(u, 'ad9361-phy',   'voltage0',    'gain_control_mode', r.GainMode, false);
    set_(u, 'ad9361-phy',   'voltage1',    'gain_control_mode', r.GainMode, false);
    if strcmpi(r.GainMode, 'manual')
        set_(u, 'ad9361-phy', 'voltage0', 'hardwaregain', r.Gain, false);
        set_(u, 'ad9361-phy', 'voltage1', 'hardwaregain', r.Gain, false);
    end

    tmp = [tempname '.iq'];
    cl = onCleanup(@() delete_(tmp));
    cmd = sprintf(['iio_readdev -u %s -b %d -s %d cf-ad9361-lpc ' ...
                   'voltage0 voltage1 voltage2 voltage3 > %s 2>/dev/null'], ...
                  u, min(nsamp, 1048576), nsamp, tmp);
    st = system(cmd);
    if st ~= 0 || ~isfile(tmp)
        error('fishball:capture2:readFailed', ...
              ['iio_readdev failed (status %d).\n' ...
               'If it said -16 EBUSY, a killed client has left a session ' ...
               'holding the DMA ON THE BOARD;\nno host-side action clears ' ...
               'that - "killall iiod" over ssh does.'], st);
    end

    f = fopen(tmp, 'r', 'ieee-le');
    v = fread(f, Inf, 'int16=>double');
    fclose(f);

    v = v(1 : floor(numel(v)/4)*4);
    v = reshape(v, 4, []).';
    x = [complex(v(:,1), v(:,2)), complex(v(:,3), v(:,4))];

    info = struct('URI', u, ...
        'CenterFrequency', get_(u,'ad9361-phy','altvoltage0','frequency',true), ...
        'SampleRate',      get_(u,'cf-ad9361-lpc','voltage0','sampling_frequency',false), ...
        'ConverterRate',   get_(u,'ad9361-phy','voltage0','sampling_frequency',false), ...
        'Gain1',           get_(u,'ad9361-phy','voltage0','hardwaregain',false), ...
        'Gain2',           get_(u,'ad9361-phy','voltage1','hardwaregain',false), ...
        'FullScale',       2047, 'Samples', size(x,1));
end

function set_(u, dev, ch, attr, val, isOut)
    if isnumeric(val), val = sprintf('%d', round(val)); else, val = char(val); end
    o = ternary(isOut, '-o', '-i');
    [st, out] = system(sprintf('iio_attr -u %s %s -c %s %s %s %s 2>&1', ...
                               u, o, dev, ch, attr, val));
    if st ~= 0
        warning('fishball:capture2:attr', 'writing %s/%s/%s: %s', ...
                dev, ch, attr, strtrim(out));
    end
end

function v = get_(u, dev, ch, attr, isOut)
    o = ternary(isOut, '-o', '-i');
    [st, out] = system(sprintf('iio_attr -u %s %s -c %s %s %s 2>/dev/null', ...
                               u, o, dev, ch, attr));
    v = NaN;
    if st == 0
        % iio_attr prints the bare value, and for some attributes it carries a
        % unit: "55.000000 dB", "3000000". Take the first number, not the last
        % thing on the line - anchoring to end-of-string silently returned NaN
        % for every attribute with a unit.
        tok = regexp(out, '-?\d+\.?\d*', 'match', 'once');
        if ~isempty(tok), v = str2double(tok); end
    end
end

function delete_(f), if isfile(f), delete(f); end, end
function r = ternary(c,a,b), if c, r = a; else, r = b; end, end
