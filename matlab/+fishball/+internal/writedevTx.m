function h = writedevTx(w, u, r)
%WRITEDEVTX  Drive TX2 with a cyclic iio_writedev, since sdrtx cannot.
%
% Returns a fishball.internal.TxHandle, which answers to release().

    if isempty(fishball.internal.which_('iio_writedev'))
        error('fishball:safeTransmit:noWritedev', ...
              ['TX2 needs iio_writedev, which is not installed.\n' ...
               '    sudo apt install libiio-utils']);
    end
    TXDEV = 'cf-ad9361-dds-core-lpc';

    % Rate, LO, and the attenuation on THIS channel. voltage1 is TX2.
    sh(sprintf('iio_attr -u %s -i -c ad9361-phy voltage0 sampling_frequency %d', ...
               u, round(r.BasebandSampleRate)));
    sh(sprintf('iio_attr -u %s -o -c ad9361-phy altvoltage1 frequency %d', ...
               u, round(r.CenterFrequency)));
    sh(sprintf('iio_attr -u %s -o -c ad9361-phy voltage1 hardwaregain %.2f', ...
               u, r.Gain));

    % Silence every DDS tone generator first. They transmit INDEPENDENTLY of
    % the DMA path, so a leftover tone from something else rides out alongside
    % whatever you are about to send and is maddening to track down.
    for k = 0:7
        sh(sprintf('iio_attr -u %s -o -c %s altvoltage%d scale 0 2>/dev/null', ...
                   u, TXDEV, k));
    end

    % Transmit full scale is +/-32767 - the DAC takes the top 12 bits of a
    % 16-bit sample. Receive is +/-2047. Scaling a transmit waveform to 2047
    % emits 24.09 dB low, which is the same trap as example 01 in reverse.
    iq = zeros(2*numel(w), 1);
    iq(1:2:end) = real(w) * 32767;
    iq(2:2:end) = imag(w) * 32767;
    iq = int16(max(min(iq, 32767), -32768));

    f = [tempname '.iq'];
    fid = fopen(f, 'w', 'ieee-le');
    fwrite(fid, iq, 'int16');
    fclose(fid);

    % -c keeps the hardware repeating the buffer. The process must stay alive:
    % the buffer belongs to its libiio session, so if it exits the board frees
    % the buffer and the carrier stops.
    cmd = sprintf(['nohup iio_writedev -u %s -c -b %d %s voltage2 voltage3 ' ...
                   '< %s >/dev/null 2>&1 & echo $!'], ...
                  u, numel(w), TXDEV, f);
    [st, out] = system(cmd);
    pid = str2double(strtrim(out));
    if st ~= 0 || isnan(pid)
        delete(f);
        error('fishball:safeTransmit:writedevFailed', ...
              'could not start iio_writedev: %s', strtrim(out));
    end
    pause(0.8);                       % let it open the buffer before we check
    h = fishball.internal.TxHandle(pid, u, 2, f);
    if ~h.isTransmitting()
        delete(f);
        error('fishball:safeTransmit:writedevDied', ...
              ['iio_writedev exited immediately. A -16 EBUSY here means a ' ...
               'stale session is\nholding the DMA on the BOARD; ' ...
               '"killall iiod" over ssh clears it.']);
    end
end

function sh(c)
    [st, o] = system([c ' >/dev/null 2>&1']);
    if st ~= 0, warning('fishball:safeTransmit:attr', '%s -> %s', c, strtrim(o)); end
end
