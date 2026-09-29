function mdl = make_fishball_qam16_model(varargin)
%MAKE_FISHBALL_QAM16_MODEL  A live 16-QAM link over the board's own loopback.
%
%   >> make_fishball_qam16_model('Open', true)
%
% !! THIS TRANSMITS !!  It needs TX1 cabled to RX1 through an attenuator.
% Default PadDb is 20. Nothing here touches TX2.
%
% WHAT IT IS. 16-QAM - a modulation carrying 4 bits per symbol as one of
% sixteen amplitude/phase points - is sent out of TX1, round a cable, and back
% into RX1. The model recovers it live: a spectrum of what came back, and a
% constellation diagram where the sixteen points should stand still and
% separate. That picture is the measurement. Smeared blobs mean noise; a
% rotating star means the carrier loop is not locked; a cross means the symbol
% timing is not.
%
% THE TRANSMITTER IS A CONSTANT BLOCK, WHICH IS NOT A CHEAT. fishball.TxSink
% runs Cyclic, meaning the hardware is handed ONE buffer and loops it for ever
% with no host involvement. Later frames are ignored by design, so a Constant
% is exactly the right source - and it sidesteps the thing that makes streaming
% transmit from MATLAB painful: measured, feeding 3 MS/s in 4096-sample frames
% produced 732 DMA underflows in one second. Cyclic has none, because nothing
% has to arrive on time.
%
% The waveform is built with a CIRCULAR convolution, not a plain one. A cyclic
% buffer wraps from the last sample to the first, so a normally-filtered block
% has a discontinuity at the seam which splatters across the band once per
% repeat. Filtering circularly makes the block exactly periodic and the seam
% disappears.
%
% RECEIVE CHAIN, block by block:
%
%   int16 -> double     the block outputs raw converter counts
%   x 1/2047            full scale on receive, NOT 32768
%   AGC                 the level off a cable is arbitrary; the constellation
%                       needs it normalised before any decision is made
%   RRC receive filter  matched to the transmit pulse shape, 4 samples per
%                       symbol down to 2
%   Symbol Synchronizer 2 samples per symbol down to 1, picking the instant to
%                       sample. Gardner: non-data-aided, so it does not need
%                       the carrier phase first
%   Carrier Synchronizer  removes the residual rotation
%   Constellation Diagram
%
% BOTH RADIOS SHARE ONE CLOCK here, because they are one chip. So there is no
% frequency offset to chase - only a fixed phase rotation and a timing offset.
% A link between two separate radios would need the same blocks working harder.

    p = inputParser;
    p.addParameter('Name', 'fishball_qam16', @(s) ischar(s) || isstring(s));
    p.addParameter('CenterFrequency', 900e6, @isnumeric);
    p.addParameter('SampleRate', 2.304e6, @isnumeric);
    p.addParameter('SamplesPerSymbol', 4, @isnumeric);
    p.addParameter('NumSymbols', 1024, @isnumeric);
    p.addParameter('Rolloff', 0.35, @isnumeric);
    p.addParameter('FilterSpan', 10, @isnumeric);
    p.addParameter('TxGain', -30, @(v) v <= 0);
    p.addParameter('RxGain', 20, @isnumeric);
    p.addParameter('PadDb', 20, @(v) v >= 0);
    p.addParameter('Open', false, @islogical);
    p.addParameter('SaveTo', '', @(s) ischar(s) || isstring(s));
    p.parse(varargin{:});
    r = p.Results;
    mdl = char(r.Name);

    sps = r.SamplesPerSymbol;
    N   = r.NumSymbols * sps;            % samples per frame, both directions
    frameTime = N / r.SampleRate;

    % ---- the waveform, periodic by construction --------------------------
    rng(7);                                        % same picture every time
    data = randi([0 15], r.NumSymbols, 1);
    sym  = qammod(data, 16, 'UnitAveragePower', true);
    h    = rcosdesign(r.Rolloff, r.FilterSpan, sps, 'sqrt');
    up   = upsample(sym, sps);
    % Circular convolution: multiply in the frequency domain. The result is
    % exactly periodic over N, so the cyclic buffer has no seam.
    txWave = ifft(fft(up) .* fft(h(:), N));
    txWave = 0.9 * txWave / max(abs(txWave));      % headroom below clipping
    refC   = qammod(0:15, 16, 'UnitAveragePower', true);

    uri = fishball.uri();
    bdclose(mdl);
    new_system(mdl);
    cl = onCleanup(@() bdclose(mdl));

    % Keep the waveform INSIDE the model, so the .slx is self-contained and
    % does not depend on a .mat sitting beside it.
    hws = get_param(mdl, 'ModelWorkspace');
    assignin(hws, 'txWave', txWave);
    assignin(hws, 'refC',   refC(:));

    % ---- transmit --------------------------------------------------------
    add_block('simulink/Sources/Constant', [mdl '/QAM16 waveform'], ...
              'Position', [40 40 160 90], 'Value', 'txWave', ...
              'SampleTime', num2str(frameTime, '%.12g'));
    txBlk = [mdl '/Fishball TX'];
    add_block('simulink/User-Defined Functions/MATLAB System', txBlk, ...
              'Position', [230 35 380 95], 'System', 'fishball.TxSink');
    set_param(txBlk, 'ChannelMapping','TX1', 'CenterFrequency', num2str(r.CenterFrequency), ...
        'BasebandSampleRate', num2str(r.SampleRate), 'SamplesPerFrame', num2str(N), ...
        'PadDb', num2str(r.PadDb), 'Gain', num2str(r.TxGain), 'Cyclic', 'on');
    set_param(txBlk, 'SimulateUsing', 'Interpreted execution');
    add_line(mdl, 'QAM16 waveform/1', 'Fishball TX/1', 'autorouting', 'on');

    % ---- receive ---------------------------------------------------------
    rxBlk = [mdl '/Fishball RX'];
    add_block('simulink/User-Defined Functions/MATLAB System', rxBlk, ...
              'Position', [40 190 190 270], 'System', 'fishball.RxSource');
    set_param(rxBlk, 'ChannelMapping','RX1', 'CenterFrequency', num2str(r.CenterFrequency), ...
        'BasebandSampleRate', num2str(r.SampleRate), 'FabricDecimation','1', ...
        'SamplesPerFrame', num2str(N), 'GainSource','Manual', ...
        'Gain', num2str(r.RxGain), 'RFBandwidth', num2str(2*r.SampleRate));
    set_param(rxBlk, 'SimulateUsing', 'Interpreted execution');

    add_block('simulink/Signal Attributes/Data Type Conversion', [mdl '/to double'], ...
              'Position', [240 200 290 230], 'OutDataTypeStr', 'double');
    add_block('simulink/Math Operations/Gain', [mdl '/full scale'], ...
              'Position', [330 200 370 230], 'Gain', '1/2047');

    load_system('commrfcorlib'); load_system('commfilt2');
    load_system('commsync2');    load_system('commsink2'); load_system('dspsnks4');

    add_block('commrfcorlib/AGC', [mdl '/AGC'], 'Position', [410 195 470 235]);

    rcBlk = [mdl '/RRC receive'];
    add_block('commfilt2/Raised Cosine Receive Filter', rcBlk, 'Position', [510 190 610 240]);
    set_param(rcBlk, 'filtType','Square root', 'R', num2str(r.Rolloff), ...
        'filtSpan', num2str(r.FilterSpan), 'N', num2str(sps), 'downFactor', '2', ...
        'InputProcessing', 'Columns as channels (frame based)');

    symBlk = [mdl '/Symbol Sync'];
    add_block('commsync2/Symbol Synchronizer', symBlk, 'Position', [650 190 750 240]);
    set_param(symBlk, 'Modulation','PAM/PSK/QAM', ...
        'TimingErrorDetector','Gardner (non-data-aided)', ...
        'SamplesPerSymbol','2', 'TimingErrorOutputPort','off');

    carBlk = [mdl '/Carrier Sync'];
    add_block('commsync2/Carrier Synchronizer', carBlk, 'Position', [790 190 890 240]);
    set_param(carBlk, 'Modulation','QAM', 'SamplesPerSymbol','1');

    conBlk = [mdl '/Constellation'];
    add_block('commsink2/Constellation Diagram', conBlk, 'Position', [940 190 1000 240]);
    try
        set_param(conBlk, 'ReferenceConstellation', 'refC', 'SamplesPerSymbol','1');
    catch
        % parameter names move between releases; the diagram still works
    end

    add_block('dspsnks4/Spectrum Analyzer', [mdl '/Spectrum'], 'Position', [240 310 300 370]);

    add_line(mdl, 'Fishball RX/1', 'to double/1',    'autorouting','on');
    add_line(mdl, 'to double/1',   'full scale/1',   'autorouting','on');
    add_line(mdl, 'full scale/1',  'AGC/1',          'autorouting','on');
    add_line(mdl, 'AGC/1',         'RRC receive/1',  'autorouting','on');
    add_line(mdl, 'RRC receive/1', 'Symbol Sync/1',  'autorouting','on');
    add_line(mdl, 'Symbol Sync/1', 'Carrier Sync/1', 'autorouting','on');
    add_line(mdl, 'Carrier Sync/1','Constellation/1','autorouting','on');
    add_line(mdl, 'Fishball RX/1', 'Spectrum/1',     'autorouting','on');

    % Radio telemetry, so the die temperature is visible on a board with a PA.
    add_block('simulink/Sinks/Display', [mdl '/radio status'], ...
              'Position', [240 400 360 440]);
    add_line(mdl, 'Fishball RX/2', 'radio status/1', 'autorouting','on');

    set_param(mdl, 'SolverType','Fixed-step', 'Solver','FixedStepDiscrete', ...
                   'FixedStep','auto', 'StopTime','inf');

    if isempty(r.SaveTo)
        out = fullfile(fileparts(mfilename('fullpath')), [mdl '.slx']);
    else
        out = char(r.SaveTo);
    end
    save_system(mdl, out);
    fprintf('  wrote %s\n', out);
    fprintf(['  %s  %.3f MHz  %.3f MSPS  %d sym/frame at %d sps  ' ...
             'TX1 %+g dB through %g dB pad -> RX1 %g dB\n'], uri, ...
            r.CenterFrequency/1e6, r.SampleRate/1e6, r.NumSymbols, sps, ...
            r.TxGain, r.PadDb, r.RxGain);
    fprintf('  symbol rate %.1f ksym/s, %.1f kbit/s at 4 bits per symbol\n', ...
            r.SampleRate/sps/1e3, 4*r.SampleRate/sps/1e3);

    if r.Open, clear cl, open_system(mdl); end
end
