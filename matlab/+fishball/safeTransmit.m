function tx = safeTransmit(waveform, varargin)
%SAFETRANSMIT  Transmit a waveform, with the things that damage boards checked.
%
%   tx = FISHBALL.SAFETRANSMIT(W, 'PadDb', 20, 'Gain', -30, ...)
%   ...
%   release(tx)                 % stops it, and the kernel re-mutes
%
% W is complex, |W| <= 1. It is scaled to the DAC's range here, so do not
% pre-scale it to 2047 - transmit full scale is +/-32767 and receive is
% +/-2047, and mixing those up is 24.09 dB in the wrong direction.
%
% 'PadDb' IS REQUIRED and there is no default. This board reaches about
% +19 dBm and its own receive port is rated +2.5 dBm, so a loopback with no
% attenuator destroys the receiver. Nothing on the board can sense what is
% attached to the transmit port - there is no coupler and no detector - so the
% number has to come from you, and stating it is the point: it makes the
% assumption explicit and checkable rather than implied.
%
% WHAT IS CHECKED
%   * that you said what pad is fitted
%   * that 19 dBm + Gain - PadDb leaves useful headroom below the receive
%     port's rating (Headroom, default 10 dB below +2.5 dBm)
%   * that the attenuation the chip ACTUALLY applied matches what was asked,
%     read back over libiio after the buffer starts - because patch 0005
%     restores a cached attenuation when a buffer opens, and a value written
%     beforehand can be silently replaced
%
% WHY transmitRepeat AND NOT A ONE-SHOT. A cyclic buffer is exempt from the
% 250 ms starvation mute (patch 0015). A one-shot from a host that cannot keep
% the DAC fed gets muted mid-transmission while the client still looks like it
% is transmitting and the receiver sees exactly zero - which is a confusing
% way to lose an afternoon.
%
% 'TxChannel' selects TX1 (default) or TX2. They take different routes -
% sdrtx cannot address TX2 any more than sdrrx can address RX2 - but both come
% back as something release() stops, so your code does not have to care.
%
% The +19 dBm figure is the self-test's capped ESTIMATE. Nobody has put a power
% meter on this port, so treat the margin as approximate and keep the pad.

    p = inputParser;
    p.addParameter('PadDb', [], @(v) isnumeric(v) && isscalar(v));
    p.addParameter('Gain', -30, @(v) isnumeric(v) && isscalar(v) && v <= 0 && v >= -89.75);
    p.addParameter('CenterFrequency', 900e6, @isnumeric);
    p.addParameter('BasebandSampleRate', 3e6, @isnumeric);
    p.addParameter('URI', '', @(s) ischar(s) || isstring(s));
    p.addParameter('Headroom', 10, @isnumeric);
    p.addParameter('TxChannel', 1, @(v) isnumeric(v) && any(v == [1 2]));
    p.addParameter('MaxOutputDbm', 19, @isnumeric);
    p.parse(varargin{:});
    r = p.Results;

    if isempty(r.PadDb)
        error('fishball:safeTransmit:noPad', ...
          ['PadDb is required and has no default.\n\n' ...
           '  This board reaches about +19 dBm. Its own receive port is rated ' ...
           '+2.5 dBm, so a\n  loopback with no attenuator destroys the ' ...
           'receiver. Fit at least 20 dB and say so:\n\n' ...
           '      fishball.safeTransmit(w, ''PadDb'', 20)\n\n' ...
           '  If this is going to an ANTENNA and not a cable, PadDb is 0 and ' ...
           'you are responsible\n  for what leaves it - this board covers ' ...
           'bands you are very likely not licensed for.']);
    end

    atRx = r.MaxOutputDbm + r.Gain - r.PadDb;
    limit = 2.5 - r.Headroom;
    if r.PadDb > 0 && atRx > limit
        error('fishball:safeTransmit:tooHot', ...
          ['Refusing: about %+.1f dBm would reach the receive port.\n\n' ...
           '  %+.0f dBm flat out %+.1f dB gain %+.1f dB pad = %+.1f dBm, ' ...
           'against a +2.5 dBm rating\n  (%.0f dB of headroom asked for).\n\n' ...
           '  Lower Gain to %+.1f dB or less, or fit %.0f dB more pad.'], ...
           atRx, r.MaxOutputDbm, r.Gain, -r.PadDb, atRx, r.Headroom, ...
           r.Gain - (atRx - limit), ceil(atRx - limit));
    end

    w = waveform(:);
    if max(abs(w)) > 1.0000001
        warning('fishball:safeTransmit:clipping', ...
                'waveform peaks at %.3f; values above 1 will clip.', max(abs(w)));
    end

    u = fishball.uri(r.URI);
    st = warning('off','plutoradio:sysobj:FirmwareIncompatible');
    restore = onCleanup(@() warning(st));
    fishball.internal.firmwareNote();

    if r.TxChannel == 1
        tx = sdrtx('Pluto', 'RadioID', u, ...
                   'CenterFrequency', r.CenterFrequency, ...
                   'BasebandSampleRate', r.BasebandSampleRate, ...
                   'Gain', r.Gain);
        transmitRepeat(tx, w);
    else
        % sdrtx cannot reach TX2 - ChannelMapping must be 1, the same limit
        % sdrrx has on receive. iio_writedev has no such opinion.
        fprintf(['  [fishball] sdrtx cannot drive TX2 (ChannelMapping must '  ...
                 'be 1), so this goes through iio_writedev -c instead.\n'    ...
                 '             release(tx) stops it either way.\n']);
        tx = fishball.internal.writedevTx(w, u, r);
    end

    % Read the attenuation back OFF THE CHIP. "A value you wrote is an
    % intention; a value you read back is a fact."
    applied = readAtten(u, r.TxChannel);
    if isnan(applied)
        warning('fishball:safeTransmit:noReadback', ...
                ['Could not read the applied attenuation back (is iio_attr ' ...
                 'installed?).\nThe transmitter is running UNVERIFIED.']);
    elseif abs(applied - r.Gain) > 0.5
        release(tx);
        error('fishball:safeTransmit:attenMismatch', ...
          ['Asked for %+.2f dB and the chip reports %+.2f dB. Transmitter ' ...
           'stopped.\n\n  A mismatch here is the failure mode patch 0005 ' ...
           'exists for: starting a buffer can\n  restore a CACHED ' ...
           'attenuation over the one you set.'], r.Gain, applied);
    else
        fprintf(['  [fishball] transmitting: %+.2f dB attenuation, confirmed ' ...
                 'on the chip.\n             through %.0f dB of pad that is ' ...
                 'about %+.1f dBm at the receiver.\n             release(tx) ' ...
                 'to stop - the kernel re-mutes on close.\n'], ...
                applied, r.PadDb, atRx);
    end
end

function a = readAtten(u, ch)
    a = NaN;
    if isempty(fishball.internal.which_('iio_attr')), return, end
    [st, o] = system(sprintf( ...
        'iio_attr -u %s -o -c ad9361-phy voltage%d hardwaregain 2>/dev/null', ...
        u, ch - 1));
    if st == 0
        t = regexp(o, '-?\d+\.?\d*', 'match', 'once');
        if ~isempty(t), a = str2double(t); end
    end
end
