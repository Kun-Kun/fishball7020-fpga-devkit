classdef RxSource < matlab.System
%FISHBALL.RXSOURCE  A Simulink source for THIS board, with both receivers.
%
% Drop a "MATLAB System" block into a model and point it at fishball.RxSource,
% or let make_fishball_rx_model.m do it for you.
%
% IN SIMULINK, SET THE BLOCK TO "Interpreted execution".
%
%     set_param(blk, 'SimulateUsing', 'Interpreted execution')
%
% The default is "Code generation", and this block cannot be generated: it
% reaches the radio through iio_readdev and iio_attr, which means system(), and
% system() has no generated equivalent. Leave the default and the model fails to
% compile with nothing more useful than
%
%     An error occurred in the block '...' during compile.
%
% Bisected to be sure, because that message names nothing: a minimal System
% object compiles; it still compiles with a StringSet, varargout, two outputs, a
% constructor, private properties and private methods calling each other; and it
% stops compiling the moment any reachable line executes system('true').
% coder.extrinsic('system') does NOT help. Interpreted execution does.
%
%   rx = fishball.RxSource('Channels','Both','CenterFrequency',868e6);
%   x  = rx();          % FrameLength-by-2 complex int16
%   release(rx)
%
% WHY THIS EXISTS RATHER THAN THE STOCK BLOCK. The ADALM-Pluto block that ships
% with the support package is written for a 1R1T radio and enforces it:
% ChannelMapping must be equal to 1. This board is 2R2T, so on the stock block
% the second receiver simply does not exist - and the second receiver is the
% interesting one, because RX1 and RX2 sit behind ONE local oscillator and ONE
% sample clock and their phase relationship is therefore a property of the
% signal rather than of two drifting clocks.
%
% This talks to iio_readdev instead, which has no such opinion, and hands
% Simulink an N-by-2 frame with both of them in it.
%
% IT ALSO ENGAGES THE FABRIC FILTER, which the stock block cannot. Setting
% Decimation to 8 makes the FPGA decimate before the samples cross the network:
% eight times less data for the host to move, and the anti-alias filtering is
% done in hardware. That is the difference between Simulink keeping up with a
% live stream and not - measured elsewhere in this repo at 113 audio underruns
% against zero. It is only safe on BOTH receivers because of patch 0021; on
% upstream wiring it would alias RX2 by about 70 dB.
%
% Full scale is +/-2047, not +/-32768 - 12-bit converters sign-extended into
% int16. See docs/matlab.md.

    properties (Nontunable)
        CenterFrequency (1,1) double {mustBePositive} = 868e6
        %SampleRate  Rate DELIVERED to the host, in Hz.
        SampleRate      (1,1) double {mustBePositive} = 2.4e6
        %Decimation  1 bypasses the fabric filter; 8 engages it.
        Decimation      (1,1) double {mustBeMember(Decimation,[1 8])} = 1
        Gain            (1,1) double = 45
        FrameLength     (1,1) double {mustBePositive} = 4096
    end

    properties (Nontunable)
        %Channels  Which receivers to output.
        Channels = 'RX1'
        %GainMode  Manual is almost always what you want - see docs/matlab.md.
        GainMode = 'manual'
    end

    properties (Hidden, Constant)
        ChannelsSet = matlab.system.StringSet({'RX1','RX2','Both'})
        GainModeSet = matlab.system.StringSet({'manual','slow_attack','fast_attack'})
    end

    properties (Nontunable)
        %StatusPeriod  Seconds between status refreshes.
        StatusPeriod (1,1) double {mustBePositive} = 1.0
        %Bandwidth  Analogue channel filter, Hz. 0 leaves it alone.
        Bandwidth (1,1) double {mustBeNonnegative} = 0
        %URI  Empty resolves the board the way every other tool here does.
        URI char = ''
    end

    properties (Access = private)
        pStream
        pStatus  = zeros(4,1)
        pLastRead = -Inf
        pFrames  = 0
    end

    methods
        function obj = RxSource(varargin)
            setProperties(obj, nargin, varargin{:});
        end
    end

    methods (Access = protected)
        function setupImpl(~)
            % DELIBERATELY EMPTY. Simulink calls setupImpl during COMPILE as
            % well as at simulation start, so opening the radio here opens it
            % twice - and the second attempt fails, because the first is still
            % holding the board's DMA. The block then dies with nothing more
            % informative than "An error occurred in the block during compile".
            %
            % So the stream is opened lazily, on the first step. Bisected with
            % a minimal System object: the same class compiles fine until
            % setupImpl touches the radio, and fails the moment it does.
        end

        function open_(obj)
            if ~isempty(obj.pStream), return, end
            bw = obj.Bandwidth;
            if bw == 0, bw = []; end
            obj.pStream = fishball.internal.RxStream( ...
                fishball.uri(obj.URI), obj.CenterFrequency, obj.SampleRate, ...
                obj.Gain, [], obj.GainMode, bw, obj.channelCode(), obj.Decimation);
            % The first frame can predate the settings taking effect, the same
            % way it can on sdrrx. Throw one away rather than hand Simulink a
            % frame captured at whatever the radio was doing before.
            obj.pStream.read(obj.FrameLength);
        end

        function [y, status] = stepImpl(obj)
            y = obj.frame();
            % Two outputs ALWAYS, and the signatures below are plain rather
            % than varargout. Simulink will only accept varargout in the
            % getOutput*Impl family when it can determine the output count
            % statically; deriving it from a property gives
            %   Invalid getOutputSizeImpl method; must be implemented when
            %   number of inputs and/or outputs is not one
            % which is emitted as a bare "error during compile" unless you
            % happen to have removed enough other overrides to expose it.
            % Terminate the status port if you do not want it - it costs a
            % throttled read and nothing else.
            obj.pFrames = obj.pFrames + 1;
            elapsed = obj.pFrames * obj.FrameLength / obj.SampleRate;
            if elapsed - obj.pLastRead >= obj.StatusPeriod
                obj.pStatus = obj.readStatus();
                obj.pLastRead = elapsed;
            end
            status = obj.pStatus;
        end

        function y = frame(obj)
            obj.open_();
            y = obj.pStream.read(obj.FrameLength);
            n = obj.FrameLength;
            w = 1 + strcmp(obj.Channels, 'Both');
            if isempty(y) || size(y,1) < n
                % A short read means the reader stopped. Simulink needs a
                % fixed-size output every step, so pad rather than error -
                % and the zeros are visible, which an exception here is not.
                y(end+1:n, 1:w) = 0;
            end
            % complex(), not a + 1i*b: MATLAB refuses complex INTEGER
            % arithmetic outright ("Complex integer arithmetic is not
            % supported"), so the obvious construction throws. Same family as
            % abs() refusing a complex int16.
            y = complex(int16(real(y)), int16(imag(y)));
        end

        function releaseImpl(obj)
            if ~isempty(obj.pStream), obj.pStream.release(); obj.pStream = []; end
        end

        function resetImpl(~), end

        % ---- what Simulink needs to know before it runs anything ----------
        function n = getNumInputsImpl(~),  n = 0; end
        function n = getNumOutputsImpl(~), n = 2; end
        function [a, b] = getOutputSizeImpl(obj)
            a = [obj.FrameLength, 1 + strcmp(obj.Channels,'Both')];
            b = [4 1];
        end
        function [a, b] = getOutputDataTypeImpl(~), a = 'int16'; b = 'double'; end
        function [a, b] = isOutputComplexImpl(~),   a = true;    b = false;    end
        function [a, b] = isOutputFixedSizeImpl(~), a = true;    b = true;     end
        function [a, b] = getOutputNamesImpl(~),    a = 'IQ';    b = 'status';  end
        function st = getSampleTimeImpl(obj)
            % One frame per FrameLength/SampleRate seconds, which is what the
            % radio actually delivers. Getting this wrong makes a model that
            % runs faster or slower than real time and looks fine.
            st = createSampleTime(obj, 'Type','Discrete', ...
                'SampleTime', obj.FrameLength / obj.SampleRate, 'OffsetTime', 0);
        end

        function flag = isInactivePropertyImpl(obj, name)
            flag = strcmp(name,'Gain') && ~strcmp(obj.GainMode,'manual');
        end

        function s = infoImpl(obj)
            s = struct('CenterFrequency', obj.CenterFrequency, ...
                       'DeliveredRate', obj.SampleRate, ...
                       'ConverterRate', obj.SampleRate * obj.Decimation, ...
                       'Channels', obj.Channels, 'FullScale', 2047);
        end
    end

    methods (Access = private)
        function v = readStatus(obj)
            % Written out rather than with an anonymous helper. A closure that
            % captures obj and calls a method on it is fine in MATLAB and is
            % what Simulink choked on here: the block failed to compile with
            % nothing more useful than "An error occurred in the block during
            % compile", and bisecting showed this method alone was the cause -
            % the same class compiles once this is four plain calls.
            u = fishball.uri(obj.URI);
            v = [ obj.attr_(u, 'ad9361-phy', 'voltage0', 'rssi')
                  obj.attr_(u, 'ad9361-phy', 'voltage1', 'rssi')
                  obj.attr_(u, 'ad9361-phy', 'temp0',    'input') / 1000
                  obj.attr_(u, 'ad9361-phy', 'voltage0', 'hardwaregain') ];
        end

        function v = attr_(obj, u, dev, ch, at)
            v = obj.num_(sprintf( ...
                'iio_attr -u %s -i -c %s %s %s 2>/dev/null', u, dev, ch, at));
        end

        function v = num_(~, cmd)
            [st, o] = system(cmd);
            v = NaN;
            if st == 0
                t = regexp(o, '-?\d+\.?\d*', 'match', 'once');
                if ~isempty(t), v = str2double(t); end
            end
        end

        function c = channelCode(obj)
            switch obj.Channels
                case 'RX1',  c = 1;
                case 'RX2',  c = 2;
                otherwise,   c = 0;
            end
        end
    end
end
