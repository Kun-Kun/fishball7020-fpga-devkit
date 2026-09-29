classdef TxSink < matlab.System
%FISHBALL.TXSINK  A Simulink transmit sink for this board: either transmitter.
%
%   tx = fishball.TxSink('ChannelMapping','TX1','PadDb',20,'Gain',-30);
%   tx(waveform);            % complex, |w| <= 1
%   release(tx)              % stops, and the kernel re-mutes
%
%   !! THIS TRANSMITS !!  PadDb is required and has no default.
%
% WHY NOT THE STOCK BLOCK. The ADALM-Pluto transmit block has the same limit as
% its receiver: ChannelMapping must be equal to 1. There is no way to reach TX2
% through it. This goes via iio_writedev, which has no opinion about how many
% transmitters your radio has.
%
% WHAT IT ADDS BEYOND A SECOND CHANNEL
%
%   SampleGpio - the four sample-locked header pins. The 12-bit DAC reads only
%   the top 12 bits of each 16-bit sample, so devkit firmware routes the
%   discarded low nibble to JP5 pins 7/9/11/13. That gives you four digital
%   outputs whose edges are locked to the RF sample that carried them - a
%   clock, a frame marker, a trigger - and it is a feature of THIS firmware
%   that no Pluto block knows about. Put the pattern in the low four bits of
%   your samples. Needs patches 0006/0007; the block says so if the attribute
%   is missing rather than failing obscurely.
%
%   The pad guard. This board reaches about +19 dBm and its own receive port is
%   rated +2.5 dBm, so PadDb is required and a level that would exceed the
%   rating is refused with the arithmetic shown. Nothing on the board can sense
%   what is attached to the transmit port - there is no coupler and no detector
%   - so the number has to come from you.
%
% TRANSMIT FULL SCALE IS +/-32767, not +/-2047. Receive is the other way. Feed
% this |w| <= 1 and it scales for you.
%
% STARVATION. If Simulink cannot keep the DAC fed, patch 0015 mutes the
% transmitter after tx_starve_timeout_ms (250 ms by default) - while the client
% still looks like it is transmitting and the receiver sees exactly zero. Keep
% the frame long enough that the model comfortably beats real time.

    properties (Nontunable)
        %CenterFrequency  Transmit frequency, Hz.
        CenterFrequency (1,1) double {mustBePositive} = 900e6
        %BasebandSampleRate  Sample rate fed to the DAC, Hz.
        BasebandSampleRate (1,1) double {mustBePositive} = 3e6
        %Gain  Transmit attenuation in dB, 0 to -89.75. Less negative is louder.
        Gain            (1,1) double {mustBeLessThanOrEqual(Gain,0)} = -30
        %PadDb  Attenuation fitted between this port and whatever it feeds.
        %
        % NaN, not -1, and deliberately unvalidated here: a property validator
        % is applied to the DEFAULT as well, so any sentinel meaning "you have
        % not told me yet" is rejected before the object exists. Checked in
        % setupImpl instead, where the error can say what to do.
        PadDb           (1,1) double = NaN
        %SamplesPerFrame  Samples per input frame.
        SamplesPerFrame (1,1) double {mustBePositive} = 4096
        %Headroom  dB kept below the +2.5 dBm receive port rating.
        Headroom        (1,1) double = 10
        %RadioID  libiio URI. Empty resolves the board the way every tool here does.
        RadioID         char = ''
    end

    properties (Nontunable)
        %ChannelMapping  Which transmitter to drive.
        ChannelMapping = 'TX1'
    end
    properties (Hidden, Constant)
        ChannelMappingSet = matlab.system.StringSet({'TX1','TX2'})
    end

    properties (Nontunable, Logical)
        %SampleGpio  Route each sample's low nibble to JP5 pins 7/9/11/13.
        SampleGpio = false

        %Cyclic  Hand the hardware ONE frame and let it repeat it for ever.
        %
        % Use this whenever your waveform repeats, which for a test signal is
        % almost always. The DMA loops the buffer with no host involvement, so
        % nothing has to be fed in real time and the 250 ms starvation watchdog
        % does not apply.
        %
        % It matters here more than on most radios. Streaming from MATLAB is
        % latency-critical and MATLAB is not fast at it: measured feeding
        % 3 MS/s in 4096-sample frames, 732 DMA underflows in one second of
        % signal. Every one of those is a gap the receiver sees as silence.
        % Cyclic sidesteps the whole problem.
        %
        % The first frame is the one transmitted. Later frames are ignored, and
        % the block says so once rather than pretending to send them.
        Cyclic = false
    end

    properties (Access = private)
        pPid = NaN, pFifo = '', pFid = -1, pUri = '', pGainSet = false
        pSaidCyclic = false
    end

    methods
        function obj = TxSink(varargin), setProperties(obj, nargin, varargin{:}); end
    end

    methods (Static, Access = protected)
        function grp = getPropertyGroupsImpl()
            radio = matlab.system.display.Section('Title','Radio', ...
                'PropertyList',{'RadioID','ChannelMapping'});
            rf = matlab.system.display.Section('Title','RF front end', ...
                'PropertyList',{'CenterFrequency','Gain'});
            safety = matlab.system.display.Section('Title','RF safety', ...
                'PropertyList',{'PadDb','Headroom'});
            data = matlab.system.display.Section('Title','Sampling', ...
                'PropertyList',{'BasebandSampleRate','SamplesPerFrame','Cyclic'});
            extra = matlab.system.display.Section('Title','This firmware only', ...
                'PropertyList',{'SampleGpio'});
            grp = [radio rf safety data extra];
        end

        function h = getHeaderImpl()
            h = matlab.system.display.Header('fishball.TxSink', ...
                'Title','Fishball7020 SDR Transmitter', ...
                'Text', ['!! THIS TRANSMITS !!  Drives TX1 or TX2 of a ' ...
                    'Fishball7020 / PlutoSky. PadDb is REQUIRED and has no ' ...
                    'default: the board reaches about +19 dBm and its own ' ...
                    'receive port is rated +2.5 dBm, so a loopback with no ' ...
                    'attenuator destroys the receiver.' newline newline ...
                    'Set "Simulate using" to Interpreted execution.' newline ...
                    'Feed it complex samples with |w| <= 1; transmit full ' ...
                    'scale is +/-32767, NOT +/-2047.']);
        end
    end

    methods (Access = protected)
        function setupImpl(obj)
            if ~isfinite(obj.PadDb) || obj.PadDb < 0
                error('fishball:TxSink:noPad', ...
                  ['PadDb is required and has no default.\n\n' ...
                   '  This board reaches about +19 dBm; its own receive port ' ...
                   'is rated +2.5 dBm, so a\n  loopback with no attenuator ' ...
                   'destroys the receiver. Fit at least 20 dB and say so.\n' ...
                   '  Feeding an ANTENNA? PadDb is 0 and what leaves it is ' ...
                   'your responsibility.']);
            end
            atRx = 19 + obj.Gain - obj.PadDb;
            if obj.PadDb > 0 && atRx > 2.5 - obj.Headroom
                error('fishball:TxSink:tooHot', ...
                  ['Refusing: about %+.1f dBm would reach the receive port.\n' ...
                   '  +19 dBm flat out %+.1f dB gain %+.1f dB pad, against a ' ...
                   '+2.5 dBm rating.'], atRx, obj.Gain, -obj.PadDb);
            end

            obj.pUri = fishball.uri(obj.RadioID);
            u = obj.pUri;
            sh(sprintf('iio_attr -u %s -i -c ad9361-phy voltage0 sampling_frequency %d', u, round(obj.BasebandSampleRate)));
            sh(sprintf('iio_attr -u %s -o -c ad9361-phy altvoltage1 frequency %d', u, round(obj.CenterFrequency)));
            % NOT the gain yet. Starting a transmit buffer fires the kernel's
            % preenable hook, which unmutes by restoring a CACHED attenuation -
            % clobbering anything written beforehand. Measured here: setting
            % -30 dB in setup and then starting the writer left the chip at
            % -89.75 dB, fully muted, with the block reporting success.
            % The gain goes on after the first frame, in stepImpl.

            % Silence every DDS generator. They transmit independently of the
            % DMA path, so a leftover tone rides out alongside your waveform.
            for k = 0:7
                sh(sprintf('iio_attr -u %s -o -c cf-ad9361-dds-core-lpc altvoltage%d scale 0', u, k));
            end

            if obj.SampleGpio
                [st,~] = system(sprintf(['iio_attr -u %s -d cf-ad9361-dds-core-lpc ' ...
                    'tx_sample_gpio_en 1 >/dev/null 2>&1'], u));
                if st ~= 0
                    warning('fishball:TxSink:noGpio', ...
                        ['tx_sample_gpio_en is not present - this firmware ' ...
                         'lacks patches 0006/0007.\nTransmitting anyway; the ' ...
                         'header pins will not follow the samples.']);
                end
            end

            obj.pFifo = [tempname '.iq'];
            if system(sprintf('mkfifo %s', obj.pFifo)) ~= 0
                error('fishball:TxSink:mkfifo','could not create a FIFO');
            end
            pair = 'voltage0 voltage1';
            if strcmp(obj.ChannelMapping,'TX2'), pair = 'voltage2 voltage3'; end
            cyc = '';
            if obj.Cyclic, cyc = '-c '; end
            [st, out] = system(sprintf( ...
                ['nohup sh -c ''iio_writedev -u %s %s-b %d cf-ad9361-dds-core-lpc %s ' ...
                 '< %s'' >/dev/null 2>&1 & echo $!'], ...
                u, cyc, obj.SamplesPerFrame, pair, obj.pFifo));
            obj.pPid = str2double(strtrim(out));
            if st ~= 0 || isnan(obj.pPid)
                obj.cleanup(); error('fishball:TxSink:spawn','iio_writedev did not start');
            end
            obj.pFid = fopen(obj.pFifo, 'w', 'ieee-le');
            if obj.pFid < 0, obj.cleanup(); error('fishball:TxSink:fifo','could not open the stream'); end
        end

        function stepImpl(obj, u)
            if obj.Cyclic && obj.pGainSet
                if ~obj.pSaidCyclic
                    obj.pSaidCyclic = true;
                    fprintf(['  [fishball] Cyclic: the first frame is looping ' ...
                             'in hardware. Later frames are\n             ' ...
                             'ignored - release and re-create to change the ' ...
                             'waveform.\n']);
                end
                return
            end
            w = double(u(:));
            if max(abs(w)) > 1.0000001
                w = w / max(abs(w));     % clipping the DAC is never what you meant
            end
            iq = zeros(2*numel(w),1);
            iq(1:2:end) = real(w) * 32767;      % transmit full scale, NOT 2047
            iq(2:2:end) = imag(w) * 32767;
            fwrite(obj.pFid, int16(max(min(iq,32767),-32768)), 'int16');

            if ~obj.pGainSet
                obj.pGainSet = true;
                c = 1 + strcmp(obj.ChannelMapping,'TX2');
                sh(sprintf('iio_attr -u %s -o -c ad9361-phy voltage%d hardwaregain %.2f', ...
                           obj.pUri, c-1, obj.Gain));
                % Read it back off the chip. A value you wrote is an intention;
                % a value you read back is a fact.
                applied = numAttr(sprintf(['iio_attr -u %s -o -c ad9361-phy ' ...
                    'voltage%d hardwaregain 2>/dev/null'], obj.pUri, c-1));
                if isfinite(applied) && abs(applied - obj.Gain) > 0.5
                    obj.cleanup();
                    error('fishball:TxSink:attenMismatch', ...
                        ['Asked for %+.2f dB, chip reports %+.2f dB. ' ...
                         'Transmitter stopped.'], obj.Gain, applied);
                end
            end
        end

        function releaseImpl(obj), obj.cleanup(); end

        function n = getNumInputsImpl(~),  n = 1; end
        function n = getNumOutputsImpl(~), n = 0; end
    end

    methods (Access = private)
        function cleanup(obj)
            if obj.pFid >= 0, try, fclose(obj.pFid); catch, end, obj.pFid = -1; end
            if ~isnan(obj.pPid)
                system(sprintf(['pkill -P %d 2>/dev/null; kill %d 2>/dev/null; ' ...
                                'sleep 0.1; kill -9 %d 2>/dev/null'], ...
                               obj.pPid, obj.pPid, obj.pPid));
                obj.pPid = NaN;
            end
            if ~isempty(obj.pFifo), system(sprintf('rm -f %s', obj.pFifo)); obj.pFifo = ''; end
            % Mute explicitly. A killed writer is exactly the case where the
            % kernel's close hook may not run.
            if ~isempty(obj.pUri)
                for c = 0:1
                    system(sprintf(['iio_attr -u %s -o -c ad9361-phy voltage%d ' ...
                        'hardwaregain -89.75 >/dev/null 2>&1'], obj.pUri, c));
                end
            end
        end
    end
end

function sh(c), system([c ' >/dev/null 2>&1']); end

function v = numAttr(cmd)
    [st, o] = system(cmd); v = NaN;
    if st == 0
        t = regexp(o, '-?\d+\.?\d*', 'match', 'once');
        if ~isempty(t), v = str2double(t); end
    end
end
