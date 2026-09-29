classdef TxHandle < handle
%TXHANDLE  A transmission started outside MATLAB's System objects.
%
% fishball.safeTransmit returns an sdrtx object for TX1 and one of these for
% TX2, because the ADALM-Pluto support package cannot reach TX2 at all -
% ChannelMapping must be 1 on sdrtx exactly as it must on sdrrx. TX2 is driven
% with `iio_writedev -c`, which has no such opinion.
%
% It answers to release(), so calling code does not care which it got:
%
%     tx = fishball.safeTransmit(w, 'PadDb', 20, 'TxChannel', 2);
%     ...
%     release(tx)
%
% The transmitting process must stay alive: a cyclic buffer belongs to the
% libiio session that created it, so when iio_writedev exits the board frees
% the buffer and the carrier stops. That is also the safety property - kill
% MATLAB and the transmission dies with it.

    properties (SetAccess = private)
        Pid      double = NaN
        URI      char   = ''
        Channel  double = 2
        TmpFile  char   = ''
    end

    methods
        function obj = TxHandle(pid, uri, channel, tmpfile)
            obj.Pid = pid; obj.URI = uri;
            obj.Channel = channel; obj.TmpFile = tmpfile;
        end

        function release(obj)
        %RELEASE  Stop transmitting, then put the chip back to full attenuation.
            if ~isnan(obj.Pid) && obj.Pid > 0
                system(sprintf('kill %d 2>/dev/null', obj.Pid));
                pause(0.3);
                system(sprintf('kill -9 %d 2>/dev/null', obj.Pid));
                obj.Pid = NaN;
            end
            % Mute explicitly rather than trusting the close. The kernel does
            % re-mute when a buffer closes, but a killed writer is exactly the
            % case docs/transmitter-safety.md says leaves buffer/enable at 1
            % with the hook never running. Belt and braces, and it is one write.
            ch = sprintf('voltage%d', obj.Channel - 1);
            system(sprintf(['iio_attr -u %s -o -c ad9361-phy %s hardwaregain ' ...
                            '-89.75 >/dev/null 2>&1'], obj.URI, ch));
            if ~isempty(obj.TmpFile) && isfile(obj.TmpFile)
                delete(obj.TmpFile); obj.TmpFile = '';
            end
        end

        function tf = isTransmitting(obj)
            tf = ~isnan(obj.Pid) && ...
                 system(sprintf('kill -0 %d 2>/dev/null', obj.Pid)) == 0;
        end

        function delete(obj)
            if obj.isTransmitting(), obj.release(); end
        end
    end
end
