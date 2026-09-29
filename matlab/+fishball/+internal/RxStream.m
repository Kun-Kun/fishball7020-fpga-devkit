classdef RxStream < handle
%RXSTREAM  A continuous two-channel receive stream, for the channel sdrrx cannot reach.
%
%   s = fishball.internal.RxStream(uri, fc, fs, gain);
%   x = s.read(nsamples);      % N-by-2 complex, RX1 and RX2
%   s.release();
%
% WHY THIS EXISTS. sdrrx cannot address RX2 (ChannelMapping must be 1), so RX2
% has to come from iio_readdev. Calling iio_readdev once per block does work
% and is far too slow to listen to: measured on this board, 0.84 s of wall
% clock for 0.200 s of signal, rising to 1.12 s by the fifth block as the
% process spawns and temp files accumulate. That is 5x too slow for real time,
% and it sounds exactly like it.
%
% So iio_readdev is started ONCE, streaming into a FIFO with no sample limit,
% and frames are read out of the pipe as they arrive. Setup cost is paid once
% and each read is just bytes.
%
% The process must stay alive for the stream to continue, which is also the
% safety property: if MATLAB dies, the reader dies with it.

    properties (SetAccess = private)
        URI   char = ''
        Pid   double = NaN
        Fifo  char = ''
        Fid   double = -1
        Channels double = 0
        Decim    double = 1
    end

    methods
        function obj = RxStream(uri, fc, fs, gain, bufSamples, gainMode, bw, chan, decim)
            if nargin < 5 || isempty(bufSamples), bufSamples = 32768; end
            if nargin < 6 || isempty(gainMode),   gainMode = 'manual'; end
            if nargin < 7, bw = []; end
            % chan: 0 = both receivers, 1 = RX1 only, 2 = RX2 only.
            %
            % ASK FOR ONE IF YOU ONLY NEED ONE. Profiled at 2.4 MS/s with
            % 0.200 s frames, the network read was 179.7 ms of a 200 ms budget
            % while all the signal processing came to 11.3 ms. Reading both
            % receivers when you want one doubles the only thing that is
            % actually expensive, and leaves 4 % headroom - which is another
            % way of spelling "underruns".
            if nargin < 8 || isempty(chan), chan = 0; end
            if nargin < 9 || isempty(decim), decim = 1; end
            obj.Channels = chan;
            obj.Decim = decim;
            obj.URI = uri;
            for t = {'iio_attr','iio_readdev'}
                if isempty(fishball.internal.which_(t{1}))
                    error('fishball:RxStream:noTools', ...
                          '%s missing - sudo apt install libiio-utils', t{1});
                end
            end
            % fs is the rate DELIVERED to the host. If it is one eighth of the
            % converter rate, the FPGA's decimate-by-8 filter is engaged and the
            % host reads eight times less data - which is the difference between
            % MATLAB keeping up with a live stream and not. There is no "filter
            % on" attribute; writing the ADC device's sampling_frequency to
            % converter/8 IS what drives GP_CONTROL bit 0 and the bypass mux.
            %
            % Since patch 0021 that filter is on BOTH receivers, so RX2 is
            % properly anti-aliased here rather than decimated raw. On upstream
            % wiring, or a STOCK_RX_FILTER=1 build, engaging it would alias RX2
            % by about 70 dB.
            conv = fs * obj.Decim;
            sh(sprintf('iio_attr -u %s -i -c ad9361-phy voltage0 sampling_frequency %d', uri, round(conv)));
            sh(sprintf('iio_attr -u %s -i -c cf-ad9361-lpc voltage0 sampling_frequency %d', uri, round(fs)));
            sh(sprintf('iio_attr -u %s -o -c ad9361-phy altvoltage0 frequency %d', uri, round(fc)));
            % The analogue channel filter. Leaving it at whatever the last user
            % set is why an AGC rides a neighbouring station instead of yours:
            % measured at 96 MHz with rf_bandwidth at 4.5 MHz, the recovered
            % deviation was 7.2 kHz rms where the station should give tens.
            if ~isempty(bw)
                for ch = {'voltage0','voltage1'}
                    sh(sprintf('iio_attr -u %s -i -c ad9361-phy %s rf_bandwidth %d', ...
                               uri, ch{1}, round(bw)));
                end
            end
            for ch = {'voltage0','voltage1'}
                sh(sprintf('iio_attr -u %s -i -c ad9361-phy %s gain_control_mode %s', ...
                           uri, ch{1}, gainMode));
                if strcmpi(gainMode, 'manual')
                    sh(sprintf('iio_attr -u %s -i -c ad9361-phy %s hardwaregain %g', ...
                               uri, ch{1}, gain));
                end
            end

            obj.Fifo = [tempname '.fifo'];
            if system(sprintf('mkfifo %s', obj.Fifo)) ~= 0
                error('fishball:RxStream:mkfifo', 'could not create a FIFO at %s', obj.Fifo);
            end
            % No -s: stream until killed.
            switch chan
                case 1, chans = 'voltage0 voltage1';
                case 2, chans = 'voltage2 voltage3';
                otherwise, chans = 'voltage0 voltage1 voltage2 voltage3';
            end
            % ELASTICITY BETWEEN THE RADIO AND MATLAB, and it is not optional.
            %
            % The reader is real-time limited: 0.200 s of signal takes 0.200 s
            % to arrive, and the processing that follows costs another ~12 ms.
            % So each turn of a listening loop takes ~212 ms and produces
            % 200 ms of audio, and the sound card starves at about 6 % per
            % frame - steadily, for ever. Profiled: read 183 ms, all the DSP
            % 11.3 ms, budget 200 ms.
            %
            % A pipe would have to hold those 12 ms to cover it, which is about
            % 115 kB here, and a default pipe is 64 kB. So iio_readdev is given
            % an elastic buffer to write into: pv -B holds seconds rather than
            % milliseconds, and the loop stops losing ground. Without pv we
            % carry on regardless, because a stuttering stream still works for
            % block captures - it is only continuous listening that suffers.
            if isempty(fishball.internal.which_('pv'))
                pipeline = sprintf('iio_readdev -u %s -b %d cf-ad9361-lpc %s', ...
                                   uri, bufSamples, chans);
            else
                pipeline = sprintf(['iio_readdev -u %s -b %d cf-ad9361-lpc %s ' ...
                                    '| pv -q -B 32M'], uri, bufSamples, chans);
            end
            [st, out] = system(sprintf('nohup sh -c ''%s'' > %s 2>/dev/null & echo $!', ...
                                       pipeline, obj.Fifo));
            obj.Pid = str2double(strtrim(out));
            if st ~= 0 || isnan(obj.Pid)
                obj.cleanupFifo();
                error('fishball:RxStream:spawn', 'could not start iio_readdev: %s', strtrim(out));
            end
            % fopen blocks until the writer opens its end, which is what we want.
            obj.Fid = fopen(obj.Fifo, 'r', 'ieee-le');
            if obj.Fid < 0
                obj.release();
                error('fishball:RxStream:fifo', 'could not open the stream');
            end
        end

        function x = read(obj, n)
        %READ  n complex samples per channel. N-by-2 for both, N-by-1 for one.
            nch = 2 + 2*(obj.Channels == 0);     % 4 int16 for both, 2 for one
            need = n * nch;
            v = fread(obj.Fid, need, 'int16=>double');
            if numel(v) < need
                x = zeros(0, nch/2);
                return
            end
            v = reshape(v, nch, []).';
            if nch == 4
                x = [complex(v(:,1), v(:,2)), complex(v(:,3), v(:,4))];
            else
                x = complex(v(:,1), v(:,2));
            end
        end

        function tf = isRunning(obj)
            tf = ~isnan(obj.Pid) && system(sprintf('kill -0 %d 2>/dev/null', obj.Pid)) == 0;
        end

        function release(obj)
            if obj.Fid >= 0, try, fclose(obj.Fid); catch, end, obj.Fid = -1; end
            if ~isnan(obj.Pid)
                % Kill the whole process GROUP: the pid is the sh, and
                % iio_readdev and pv are its children. Killing only the shell
                % leaves iio_readdev streaming and holding the board's DMA,
                % which then refuses the next session with -16 EBUSY.
                system(sprintf(['pkill -P %d 2>/dev/null; kill %d 2>/dev/null; ' ...
                                'sleep 0.15; pkill -9 -P %d 2>/dev/null; ' ...
                                'kill -9 %d 2>/dev/null'], ...
                               obj.Pid, obj.Pid, obj.Pid, obj.Pid));
                obj.Pid = NaN;
            end
            obj.cleanupFifo();
        end

        function delete(obj), obj.release(); end
    end

    methods (Access = private)
        function cleanupFifo(obj)
            if ~isempty(obj.Fifo)
                system(sprintf('rm -f %s', obj.Fifo));
                obj.Fifo = '';
            end
        end
    end
end

function sh(c)
    system([c ' >/dev/null 2>&1']);
end
