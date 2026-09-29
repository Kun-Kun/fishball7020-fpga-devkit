classdef RxSource < matlab.System
%FISHBALL.RXSOURCE  Receive from a Fishball7020 / PlutoSky, in MATLAB or Simulink.
%
%   rx = fishball.RxSource('ChannelMapping','RX1+RX2','CenterFrequency',868e6);
%   [iq, status] = rx();
%   release(rx)
%
% In Simulink, drop a "MATLAB System" block and point it at fishball.RxSource.
%
% WHY NOT THE STOCK ADALM-PLUTO BLOCK. That block is written for a 1R1T radio
% and enforces it: ChannelMapping must be equal to 1. This board is 2R2T, so on
% the stock block the second receiver does not exist - and the second receiver
% is the interesting one, because both sit behind ONE local oscillator and ONE
% sample clock, which makes the phase between them a property of the signal
% rather than of two drifting clocks.
%
% IN SIMULINK, SET THE BLOCK TO "Interpreted execution".
%
%     set_param(blk, 'SimulateUsing', 'Interpreted execution')
%
% The default is "Code generation" and this block cannot be generated: it
% reaches the radio through iio_readdev and iio_attr, which means system(), and
% system() has no generated equivalent. Leave the default and the model fails to
% compile with only "An error occurred in the block during compile", which names
% nothing. Bisected: a minimal System object compiles, and still compiles with a
% StringSet, varargout, two outputs, a constructor and private methods calling
% each other - and stops the moment any reachable line executes system('true').
% coder.extrinsic('system') does not help.
%
% FULL SCALE IS +/-2047, not +/-32768: the converters are 12-bit, sign-extended
% into int16. Transmit is the other way round and uses the full +/-32767.

    % =====================================================================
    properties (Nontunable)
        %RadioID  libiio URI. Empty resolves the board the way every tool here does.
        RadioID char = ''
    end

    properties (Nontunable)
        %ChannelMapping  Which receivers to output.
        ChannelMapping = 'RX1'
    end

    properties (Nontunable)
        %CenterFrequency  Tuned frequency, Hz. AD9361 range 70 MHz - 6 GHz.
        CenterFrequency (1,1) double {mustBePositive} = 868e6
        %RFBandwidth  Analogue channel filter, Hz. Chip allows 200 kHz - 56 MHz.
        %
        % Set this to the signal you want. Left wide, an AGC responds to
        % whatever else is in the band rather than to your signal.
        RFBandwidth (1,1) double {mustBeNonnegative} = 0
        %RFPort  Which input the receiver listens to.
        %
        % MEASURED ON THIS FIRMWARE: only A Balanced is accepted. The chip
        % advertises twelve in rf_port_select_available - A/B/C balanced, the
        % six single-ended halves, and TX Monitor 1/2 which would point the
        % receiver at this board's own transmitter with no cable - and the
        % driver refuses every one of them but A_BALANCED with
        %
        %     error Invalid argument (22) while writing 'rf_port_select'
        %
        % from an idle ENSM state as readily as from a running one. The lever
        % is kept because it is a real AD9361 attribute and a different build
        % may honour it; it now SAYS SO when it is refused instead of quietly
        % leaving you on the port you were already on.
        RFPort = 'A Balanced'
    end

    properties (Nontunable)
        %GainSource  Manual, or one of the chip's AGC modes.
        %
        % Manual is usually right on this board. An AGC counts the receiver's
        % own LO leakage as signal and can raise the gain until that leak, not
        % your signal, hits its target - measured at 96 MHz, AGC put the DC bin
        % 29 dB ABOVE the station where manual 65 dB put it 31 dB below.
        GainSource = 'Manual'
        %Gain  Receive gain, dB. Range moves with frequency: [-1 73] below
        %1.3 GHz, [-3 71] to 4 GHz, [-10 62] above.
        Gain (1,1) double = 45
    end

    properties (Nontunable)
        %BasebandSampleRate  Rate DELIVERED to the host, Hz.
        BasebandSampleRate (1,1) double {mustBePositive} = 2.4e6
        %FabricDecimation  1 bypasses the FPGA filter; 8 engages it.
        %
        % 8 means the FPGA decimates before the samples cross the network -
        % eight times less data, and the anti-alias filtering done in hardware.
        % Converter rate is BasebandSampleRate x FabricDecimation, and must
        % clear the AD9361's 2.083 MSPS floor.
        FabricDecimation (1,1) double {mustBeMember(FabricDecimation,[1 8])} = 1
        %SamplesPerFrame  Samples per output frame, per channel.
        SamplesPerFrame (1,1) double {mustBePositive} = 4096
    end

    properties (Nontunable, Logical)
        %EnableQuadratureTracking  Correct IQ imbalance (image rejection).
        EnableQuadratureTracking = true
        %EnableRFDCTracking  Correct the RF-stage DC offset.
        EnableRFDCTracking = true
        %EnableBasebandDCTracking  Correct the baseband DC offset.
        EnableBasebandDCTracking = true
        %EnableRxFIR  Enable the AD9361's own decimating FIR.
        %
        % Required below 2.083 MSPS at the converter, and off above it.
        %
        % There is nothing to enable until a set of coefficients is loaded:
        % with none, the driver refuses this with Invalid argument (22).
        % Load one first via the phy's filter_fir_config attribute - see
        % firmware/scripts/gen_fir_coe.m for designing the taps.
        EnableRxFIR = false
    end

    properties (Nontunable)
        %ControlPorts  Expose levers as Simulink INPUT ports.
        %
        %   'none'  no inputs; the dialog values are used and fixed
        %   'tune'  Fc
        %   'full'  Fc, gain, RF bandwidth
        %   'all'   Fc, gain1, gain2, RF bandwidth, gain mode, RF port
        %
        % gain1/gain2 are separate because the two receivers differ by about
        % 1.5 dB on this board, so one shared number is a compromise.
        %
        %   gain mode : 0 manual, 1 AGC slow attack, 2 AGC fast attack, 3 hybrid
        %   RF port   : 1 A Balanced ... 10 TX Monitor 1, 11 TX Monitor 2
        %               - but see RFPort: this firmware accepts only 1.
        %
        % A NaN input is left alone, so a model can drive one lever without
        % wiring a constant to every port. A value is pushed only WHEN IT
        % CHANGES: each change is an iio_attr round trip of roughly 10-30 ms
        % against a 14 ms frame at 288 kHz, so drive these from something slow.
        %
        % BasebandSampleRate and FabricDecimation are NOT offered as ports.
        % They change the buffer geometry, so altering them means rebuilding
        % the stream; the six above do not.
        ControlPorts = 'none'
        %StatusUpdatePeriod  Seconds between refreshes of the status output.
        StatusUpdatePeriod (1,1) double {mustBePositive} = 1.0
    end

    properties (Hidden, Constant)
        ChannelMappingSet = matlab.system.StringSet({'RX1','RX2','RX1+RX2'})
        GainSourceSet     = matlab.system.StringSet({'Manual', ...
            'AGC Slow Attack','AGC Fast Attack','AGC Hybrid'})
        RFPortSet         = matlab.system.StringSet({'A Balanced','B Balanced', ...
            'C Balanced','TX Monitor 1','TX Monitor 2'})
        ControlPortsSet   = matlab.system.StringSet({'none','tune','full','all'})
    end

    properties (Access = private)
        pStream, pStatus = zeros(4,1), pLastRead = -Inf, pFrames = 0, pLast = struct()
        pWarned = struct()
    end

    % =====================================================================
    methods
        function obj = RxSource(varargin)
            setProperties(obj, nargin, varargin{:});
        end
    end

    methods (Static, Access = protected)
        function grp = getPropertyGroupsImpl()
            radio = matlab.system.display.Section('Title','Radio', ...
                'PropertyList',{'RadioID','ChannelMapping'});
            rf = matlab.system.display.Section('Title','RF front end', ...
                'PropertyList',{'CenterFrequency','RFBandwidth','RFPort'});
            gain = matlab.system.display.Section('Title','Gain', ...
                'PropertyList',{'GainSource','Gain'});
            data = matlab.system.display.Section('Title','Sampling', ...
                'PropertyList',{'BasebandSampleRate','FabricDecimation','SamplesPerFrame'});
            corr = matlab.system.display.Section('Title','Corrections', ...
                'PropertyList',{'EnableQuadratureTracking','EnableRFDCTracking', ...
                                'EnableBasebandDCTracking','EnableRxFIR'});
            sl = matlab.system.display.Section('Title','Simulink', ...
                'PropertyList',{'ControlPorts','StatusUpdatePeriod'});
            grp = [radio rf gain data corr sl];
        end

        function h = getHeaderImpl()
            h = matlab.system.display.Header('fishball.RxSource', ...
                'Title','Fishball7020 SDR Receiver', ...
                'Text', ['Receive from a Fishball7020 / PlutoSky (Zynq-7020 + ' ...
                    'AD9361). Unlike the stock ADALM-Pluto block this reaches ' ...
                    'BOTH receivers, can engage the FPGA decimating filter, ' ...
                    'and outputs radio telemetry.' newline newline ...
                    'Set "Simulate using" to Interpreted execution.' newline ...
                    'Output IQ is int16 converter counts; full scale is ' ...
                    '+/-2047, NOT +/-32768.']);
        end
    end

    methods (Access = protected)
        function setupImpl(~)
            % Deliberately empty: Simulink calls setupImpl during COMPILE as
            % well as at start, so opening the radio here opens it twice and
            % the second attempt fails while the first holds the DMA. Opened
            % lazily instead, on the first step.
        end

        function [iq, status] = stepImpl(obj, varargin)
            % Open FIRST, then apply the control inputs. The stream's
            % constructor sets the LO from the dialog, so applying inputs
            % before it would have the first frame silently use the dialog
            % value - measured: commanded 88.8 MHz, chip reported 868.
            obj.open_();
            if obj.applyControls(varargin{:})
                obj.restart();       % see restart(): the old samples come first
            end
            iq = obj.frame();

            obj.pFrames = obj.pFrames + 1;
            elapsed = obj.pFrames * obj.SamplesPerFrame / obj.BasebandSampleRate;
            if elapsed - obj.pLastRead >= obj.StatusUpdatePeriod
                obj.pStatus = obj.readStatus();
                obj.pLastRead = elapsed;
            end
            status = obj.pStatus;
        end

        function releaseImpl(obj)
            if ~isempty(obj.pStream), obj.pStream.release(); obj.pStream = []; end
            obj.pLast = struct(); obj.pFrames = 0; obj.pLastRead = -Inf;
            obj.pWarned = struct();
        end
        function resetImpl(~), end

        % ---- what Simulink must know before it runs ----------------------
        function n = getNumInputsImpl(obj)
            switch obj.ControlPorts
                case 'tune', n = 1;
                case 'full', n = 3;
                case 'all',  n = 6;
                otherwise,   n = 0;
            end
        end
        function varargout = getInputNamesImpl(obj)
            switch obj.ControlPorts
                case 'tune', varargout = {'Fc'};
                case 'full', varargout = {'Fc','gain','BW'};
                case 'all',  varargout = {'Fc','gain1','gain2','BW','gainMode','RFport'};
                otherwise,   varargout = {};
            end
        end
        % Two FIXED outputs with plain signatures. Simulink only accepts
        % varargout in this family when it can determine the count statically;
        % deriving it from a property gives "Invalid getOutputSizeImpl method".
        function n = getNumOutputsImpl(~), n = 2; end
        function [a, b] = getOutputSizeImpl(obj)
            a = [obj.SamplesPerFrame, obj.nChan()]; b = [4 1];
        end
        function [a, b] = getOutputDataTypeImpl(~), a = 'int16'; b = 'double'; end
        function [a, b] = isOutputComplexImpl(~),   a = true;    b = false;    end
        function [a, b] = isOutputFixedSizeImpl(~), a = true;    b = true;     end
        function [a, b] = getOutputNamesImpl(~),    a = 'IQ';    b = 'status';  end
        function st = getSampleTimeImpl(obj)
            st = createSampleTime(obj, 'Type','Discrete', ...
                'SampleTime', obj.SamplesPerFrame / obj.BasebandSampleRate, ...
                'OffsetTime', 0);
        end
        function flag = isInactivePropertyImpl(obj, name)
            flag = strcmp(name,'Gain') && ~strcmp(obj.GainSource,'Manual');
        end
        function s = infoImpl(obj)
            s = struct('CenterFrequency', obj.CenterFrequency, ...
                       'BasebandSampleRate', obj.BasebandSampleRate, ...
                       'ConverterRate', obj.BasebandSampleRate*obj.FabricDecimation, ...
                       'ChannelMapping', obj.ChannelMapping, 'FullScale', 2047);
        end
    end

    % =====================================================================
    methods (Access = private)
        function n = nChan(obj), n = 1 + strcmp(obj.ChannelMapping,'RX1+RX2'); end

        function c = channelCode(obj)
            switch obj.ChannelMapping
                case 'RX1',  c = 1;
                case 'RX2',  c = 2;
                otherwise,   c = 0;
            end
        end

        function open_(obj)
            if ~isempty(obj.pStream), return, end
            % Whatever the control ports last commanded WINS over the dialog,
            % so a stream rebuilt after a retune comes back on the new setting
            % rather than snapping to the dialog value.
            fc   = obj.eff('Fc', obj.CenterFrequency);
            gain = obj.eff('g1', obj.Gain);
            bw   = obj.eff('bw', obj.RFBandwidth); if bw == 0, bw = []; end
            if isfield(obj.pLast,'gm')
                modes = {'manual','slow_attack','fast_attack','hybrid'};
                mode  = modes{min(max(round(obj.pLast.gm),0),3) + 1};
            else
                mode  = obj.gainModeString(obj.GainSource);
            end
            obj.pStream = fishball.internal.RxStream( ...
                fishball.uri(obj.RadioID), fc, ...
                obj.BasebandSampleRate, gain, [], mode, bw, ...
                obj.channelCode(), obj.FabricDecimation);
            obj.applyCorrections();
            obj.applyPort(obj.RFPort);
            u = fishball.uri(obj.RadioID);
            if isfield(obj.pLast,'g2'), obj.setGain(u, 1, obj.pLast.g2); end
            if isfield(obj.pLast,'rp'), obj.setPortIdx(u, obj.pLast.rp); end
            % The first frame can predate the settings taking effect, the same
            % way it can on sdrrx. Discard one.
            obj.pStream.read(obj.SamplesPerFrame);
        end

        function v = eff(obj, key, dflt)
            if isfield(obj.pLast, key), v = obj.pLast.(key); else, v = dflt; end
        end

        % A CHANGED SETTING MEANS A NEW STREAM. Writing the attribute is not
        % enough: iio_readdev, the FIFO, the socket and the board's own DMA ring
        % are all holding samples captured at the OLD setting, and they come out
        % first. MEASURED over USB at 2.304 MSPS with 4096-sample frames: after
        % commanding a 500 kHz retune, the tone stayed at the old offset for
        % THIRTY-FOUR more frames and only moved on the 35th - with the LO
        % register reading the new frequency the whole time. Read the register
        % and it looks instant; look at the samples and it is not.
        %
        % So the stream is torn down and rebuilt, which is the same conclusion
        % pyadi-iio reaches with rx_destroy_buffer() after any configuration
        % change. It costs one stream setup, and it is the difference between a
        % scanner that shows the band and a scanner that shows the previous
        % step.
        function restart(obj)
            if ~isempty(obj.pStream), obj.pStream.release(); obj.pStream = []; end
            obj.open_();
        end

        function y = frame(obj)
            y = obj.pStream.read(obj.SamplesPerFrame);
            n = obj.SamplesPerFrame; w = obj.nChan();
            if isempty(y) || size(y,1) < n
                % Simulink needs a fixed-size output every step, so pad rather
                % than error - and zeros are visible, where an exception is not.
                y(end+1:n, 1:w) = 0;
            end
            y = complex(int16(real(y)), int16(imag(y)));
        end

        function applyCorrections(obj)
            u = fishball.uri(obj.RadioID);
            en = @(b) sprintf('%d', b);
            for ch = 0:1
                c = sprintf('-i -c ad9361-phy voltage%d', ch);
                obj.writeAttr(u, c, 'quadrature_tracking_en',   en(obj.EnableQuadratureTracking));
                obj.writeAttr(u, c, 'rf_dc_offset_tracking_en', en(obj.EnableRFDCTracking));
                obj.writeAttr(u, c, 'bb_dc_offset_tracking_en', en(obj.EnableBasebandDCTracking));
                obj.writeAttr(u, c, 'filter_fir_en',            en(obj.EnableRxFIR));
            end
        end

        % EVERY WRITE IS CHECKED. iio_attr exits 1 and prints the reason when
        % the driver refuses, and the earlier version of this block sent all
        % of these to /dev/null - so a refused setting looked exactly like an
        % applied one. Two of the levers here ARE refused on this firmware
        % (see RFPort and EnableRxFIR), and both looked like they worked.
        %
        % Once per attribute, not once per call: these sit on a per-frame path
        % and a warning every 14 ms is a hang, not a diagnostic.
        function ok = writeAttr(obj, u, spec, attr, val)
            [st, o] = system(sprintf('iio_attr -u %s %s %s %s 2>&1', ...
                                     u, spec, attr, val));
            ok = (st == 0);
            if ~ok, obj.warnOnce(attr, val, o); end
        end

        function warnOnce(obj, attr, val, msg)
            key = matlab.lang.makeValidName(attr);
            if isfield(obj.pWarned, key), return, end
            obj.pWarned.(key) = true;
            hint = '';
            switch attr
                case 'rf_port_select'
                    hint = sprintf(['\n  This firmware accepts only A_BALANCED ' ...
                        'on receive, whatever\n  rf_port_select_available ' ...
                        'lists. The receiver stays where it was.']);
                case 'filter_fir_en'
                    hint = sprintf(['\n  No FIR coefficients are loaded, so ' ...
                        'there is nothing to enable.\n  Load a set through ' ...
                        'filter_fir_config first.']);
            end
            warning('fishball:RxSource:attrRejected', ...
                ['The radio refused %s = %s.\n  %s%s'], ...
                attr, val, strtrim(msg), hint);
        end

        % ---- runtime control --------------------------------------------
        function changed = applyControls(obj, varargin)
            changed = false;
            if isempty(varargin), return, end
            u = fishball.uri(obj.RadioID);
            n = numel(varargin);
            c = @(k,v,f) obj.setIfChanged(k, v, f);
            changed = c('Fc', varargin{1}, @(v) obj.tune(u, v));
            if n == 3
                changed = c('g1', varargin{2}, @(v) obj.setGain(u, 0, v)) || changed;
                changed = c('g2', varargin{2}, @(v) obj.setGain(u, 1, v)) || changed;
                changed = c('bw', varargin{3}, @(v) obj.setBw(u, v))      || changed;
            elseif n >= 6
                changed = c('g1', varargin{2}, @(v) obj.setGain(u, 0, v)) || changed;
                changed = c('g2', varargin{3}, @(v) obj.setGain(u, 1, v)) || changed;
                changed = c('bw', varargin{4}, @(v) obj.setBw(u, v))      || changed;
                changed = c('gm', varargin{5}, @(v) obj.setGainMode(u, v))|| changed;
                changed = c('rp', varargin{6}, @(v) obj.setPortIdx(u, v)) || changed;
            end
        end

        function did = setIfChanged(obj, key, val, applyFcn)
            did = false;
            val = double(val);
            if ~isfinite(val), return, end          % NaN = leave alone
            if isfield(obj.pLast, key) && isequaln(obj.pLast.(key), val), return, end
            applyFcn(val);
            obj.pLast.(key) = val;
            did = true;
        end

        function tune(obj, u, fc)
            if fc < 70e6 || fc > 6e9
                warning('fishball:RxSource:loRange', ...
                    '%.3f MHz is outside the AD9361''s 70 MHz - 6 GHz range; ignored.', fc/1e6);
                return
            end
            obj.writeAttr(u, '-o -c ad9361-phy altvoltage0', 'frequency', ...
                          sprintf('%d', round(fc)));
        end

        function setGain(obj, u, ch, g)
            obj.writeAttr(u, sprintf('-i -c ad9361-phy voltage%d', ch), ...
                          'hardwaregain', sprintf('%.2f', g));
        end

        function setBw(obj, u, b)
            b = min(max(b, 200e3), 56e6);          % rf_bandwidth_available
            for ch = 0:1
                obj.writeAttr(u, sprintf('-i -c ad9361-phy voltage%d', ch), ...
                              'rf_bandwidth', sprintf('%d', round(b)));
            end
        end

        function setGainMode(obj, u, m)
            modes = {'manual','slow_attack','fast_attack','hybrid'};
            k = round(m) + 1;
            if k < 1 || k > numel(modes)
                warning('fishball:RxSource:gainMode', ...
                    'gainMode %g is not 0..3; ignored.', m); return
            end
            for ch = 0:1
                obj.writeAttr(u, sprintf('-i -c ad9361-phy voltage%d', ch), ...
                              'gain_control_mode', modes{k});
            end
        end

        function setPortIdx(obj, u, idx)
            ports = {'A_BALANCED','B_BALANCED','C_BALANCED','A_N','A_P','B_N', ...
                     'B_P','C_N','C_P','TX_MONITOR1','TX_MONITOR2','TX_MONITOR1_2'};
            k = round(idx);
            if k < 1 || k > numel(ports)
                warning('fishball:RxSource:rfPort', ...
                    'RFport %g is not 1..%d; ignored.', idx, numel(ports)); return
            end
            obj.writePort(u, ports{k});
        end

        function applyPort(obj, name)
            map = struct('A_Balanced','A_BALANCED', 'B_Balanced','B_BALANCED', ...
                         'C_Balanced','C_BALANCED', 'TX_Monitor_1','TX_MONITOR1', ...
                         'TX_Monitor_2','TX_MONITOR2');
            key = strrep(name, ' ', '_');
            if isfield(map, key)
                obj.writePort(fishball.uri(obj.RadioID), map.(key));
            end
        end

        function writePort(obj, u, hw)
            for ch = 0:1
                obj.writeAttr(u, sprintf('-i -c ad9361-phy voltage%d', ch), ...
                              'rf_port_select', hw);
            end
        end

        function m = gainModeString(~, src)
            switch src
                case 'AGC Slow Attack', m = 'slow_attack';
                case 'AGC Fast Attack', m = 'fast_attack';
                case 'AGC Hybrid',      m = 'hybrid';
                otherwise,              m = 'manual';
            end
        end

        % ---- telemetry ---------------------------------------------------
        function v = readStatus(obj)
            u = fishball.uri(obj.RadioID);
            v = [ obj.attr_(u, 'voltage0', 'rssi')
                  obj.attr_(u, 'voltage1', 'rssi')
                  obj.attr_(u, 'temp0',    'input') / 1000
                  obj.attr_(u, 'voltage0', 'hardwaregain') ];
        end

        function v = attr_(obj, u, ch, at)
            v = obj.num_(sprintf('iio_attr -u %s -i -c ad9361-phy %s %s 2>/dev/null', ...
                                 u, ch, at));
        end

        % Reads only - every write goes through writeAttr, which checks.
        function v = num_(~, cmd)
            [st, o] = system(cmd);
            v = NaN;
            if st == 0
                t = regexp(o, '-?\d+\.?\d*', 'match', 'once');
                if ~isempty(t), v = str2double(t); end
            end
        end
    end
end
