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
    end

    methods
        function obj = RxStream(uri, fc, fs, gain, bufSamples)
            if nargin < 5, bufSamples = 32768; end
            obj.URI = uri;
            for t = {'iio_attr','iio_readdev'}
                if isempty(fishball.internal.which_(t{1}))
                    error('fishball:RxStream:noTools', ...
                          '%s missing - sudo apt install libiio-utils', t{1});
                end
            end
            sh(sprintf('iio_attr -u %s -i -c ad9361-phy voltage0 sampling_frequency %d', uri, round(fs)));
            sh(sprintf('iio_attr -u %s -i -c cf-ad9361-lpc voltage0 sampling_frequency %d', uri, round(fs)));
            sh(sprintf('iio_attr -u %s -o -c ad9361-phy altvoltage0 frequency %d', uri, round(fc)));
            for ch = {'voltage0','voltage1'}
                sh(sprintf('iio_attr -u %s -i -c ad9361-phy %s gain_control_mode manual', uri, ch{1}));
                sh(sprintf('iio_attr -u %s -i -c ad9361-phy %s hardwaregain %g', uri, ch{1}, gain));
            end

            obj.Fifo = [tempname '.fifo'];
            if system(sprintf('mkfifo %s', obj.Fifo)) ~= 0
                error('fishball:RxStream:mkfifo', 'could not create a FIFO at %s', obj.Fifo);
            end
            % No -s: stream until killed.
            [st, out] = system(sprintf( ...
                ['nohup iio_readdev -u %s -b %d cf-ad9361-lpc ' ...
                 'voltage0 voltage1 voltage2 voltage3 > %s 2>/dev/null & echo $!'], ...
                uri, bufSamples, obj.Fifo));
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
        %READ  n complex samples per channel, as N-by-2.
            need = n * 4;                       % 4 int16 per sample pair-pair
            v = fread(obj.Fid, need, 'int16=>double');
            if numel(v) < need
                x = zeros(0,2);
                return
            end
            v = reshape(v, 4, []).';
            x = [complex(v(:,1), v(:,2)), complex(v(:,3), v(:,4))];
        end

        function tf = isRunning(obj)
            tf = ~isnan(obj.Pid) && system(sprintf('kill -0 %d 2>/dev/null', obj.Pid)) == 0;
        end

        function release(obj)
            if obj.Fid >= 0, try, fclose(obj.Fid); catch, end, obj.Fid = -1; end
            if ~isnan(obj.Pid)
                system(sprintf('kill %d 2>/dev/null; sleep 0.1; kill -9 %d 2>/dev/null', ...
                               obj.Pid, obj.Pid));
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
