function mdl = make_fishball_rx_model(varargin)
%MAKE_FISHBALL_RX_MODEL  Build fishball_rx.slx from code.
%
%   >> make_fishball_rx_model                       % build and save
%   >> make_fishball_rx_model('Open', true)         % ... and open it
%   >> make_fishball_rx_model('CenterFrequency', 90.4e6)
%
% WHY A GENERATOR. An .slx is a binary. It works, and in a repository it cannot
% be reviewed, diffed or merged - you cannot see what changed between two
% versions of it, which is most of the point of keeping it in version control.
% So the model is built from this file, and BOTH are committed: the .slx so it
% opens without running anything, and this so you can see what is in it.
%
% That is the same arrangement the rest of this repository uses for generated
% things - docs/img/make_*_svg.py.
%
% TWO RECEIVERS. 'Source','fishball' (the default) uses fishball.RxSource from
% this repository and can output RX1, RX2 or both. 'Source','pluto' uses the
% stock ADALM-Pluto block, which is written for a 1R1T radio and enforces
% ChannelMapping = 1 - so on that path RX2 does not exist.
%
% See make_fishball_scanner_model.m for the control-port version, where the
% model drives the radio rather than only reading it.

    p = inputParser;
    p.addParameter('Name', 'fishball_rx', @(s) ischar(s) || isstring(s));
    p.addParameter('CenterFrequency', 90.4e6, @isnumeric);
    p.addParameter('ConverterRate', 2.304e6, @isnumeric);
    p.addParameter('Gain', 45, @isnumeric);
    p.addParameter('SamplesPerFrame', 4096, @isnumeric);
    % 'pluto'    the stock ADALM-Pluto block. One receiver, ever.
    % 'fishball' this repo's own MATLAB System block: BOTH receivers, the
    %            fabric decimator, and a telemetry output. See RxSource.m.
    p.addParameter('Source', 'fishball', @(s) any(strcmpi(s,{'pluto','fishball'})));
    p.addParameter('Channels', 'Both', @(s) any(strcmpi(s,{'RX1','RX2','Both'})));
    p.addParameter('FabricDecimation', 8, @(v) any(v == [1 8]));
    p.addParameter('Open', false, @islogical);
    p.addParameter('SaveTo', '', @(s) ischar(s) || isstring(s));
    p.parse(varargin{:});
    r = p.Results;
    mdl = char(r.Name);

    uri = fishball.uri();

    bdclose(mdl);            % no-op if it is not open
    new_system(mdl);
    cl = onCleanup(@() bdclose(mdl));

    % ---- the receiver ---------------------------------------------------
    if strcmpi(r.Source, 'fishball')
        rxBlk = [mdl '/Fishball RX'];
        add_block('simulink/User-Defined Functions/MATLAB System', rxBlk, ...
                  'Position', [80 80 260 180], 'System', 'fishball.RxSource');
        set_param(rxBlk, ...
            'CenterFrequency',    num2str(r.CenterFrequency), ...
            'BasebandSampleRate', num2str(r.ConverterRate / r.FabricDecimation), ...
            'FabricDecimation',   num2str(r.FabricDecimation), ...
            'Gain',               num2str(r.Gain), ...
            'SamplesPerFrame',    num2str(r.SamplesPerFrame), ...
            'ChannelMapping',     chanStr(r.Channels));
        % Interpreted execution is REQUIRED, not a preference: this block
        % reaches the radio with system(), which has no generated equivalent,
        % and the default "Code generation" setting makes the model fail to
        % compile with a message that names nothing. See RxSource.m.
        set_param(rxBlk, 'SimulateUsing', 'Interpreted execution');
        srcPort = 'Fishball RX/1';
    else
    load_system('plutoradiolib');
    rxBlk = [mdl '/Pluto Receiver'];
    % sprintf, because the block's NAME contains a real newline - Simulink
    % library blocks are named across two lines and that line break is part of
    % the name. 'ADALM-Pluto Radio\nReceiver' in single quotes is the two
    % characters backslash-n and does not match anything.
    add_block(sprintf('plutoradiolib/ADALM-Pluto Radio\nReceiver'), rxBlk, ...
              'Position', [80 80 260 180]);
    set_param(rxBlk, ...
        'RadioID',            uri, ...
        'CenterFrequency',    num2str(r.CenterFrequency), ...
        'BasebandSampleRate', num2str(r.ConverterRate), ...
        'GainSource',         'Manual', ...
        'Gain',               num2str(r.Gain), ...
        'SamplesPerFrame',    num2str(r.SamplesPerFrame), ...
        'OutputDataType',     'int16');
        srcPort = 'Pluto Receiver/1';
    end

    % ---- somewhere to look at it ----------------------------------------
    load_system('dspsnks4');
    saBlk = [mdl '/Spectrum Analyzer'];
    add_block('dspsnks4/Spectrum Analyzer', saBlk, 'Position', [420 95 480 165]);

    add_line(mdl, srcPort, 'Spectrum Analyzer/1', 'autorouting', 'on');

    % The custom block's second output is telemetry the stock Pluto block does
    % not have: [rssi1, rssi2, AD9361 degC, applied gain]. Wire it to a Display
    % so it is visible rather than dangling - on a board with a power amplifier
    % the die temperature is not decoration.
    if strcmpi(r.Source, 'fishball')
        dsp = [mdl '/radio status'];
        add_block('simulink/Sinks/Display', dsp, 'Position', [420 220 520 280]);
        add_line(mdl, 'Fishball RX/2', 'radio status/1', 'autorouting', 'on');
    end

    % ---- solver: a radio is a fixed-rate source --------------------------
    set_param(mdl, 'SolverType', 'Fixed-step', 'Solver', 'FixedStepDiscrete', ...
                   'FixedStep', 'auto', 'StopTime', 'inf');

    % ---- save -----------------------------------------------------------
    if isempty(r.SaveTo)
        out = fullfile(fileparts(mfilename('fullpath')), [mdl '.slx']);
    else
        out = char(r.SaveTo);
    end
    save_system(mdl, out);
    fprintf('  wrote %s\n', out);
    if strcmpi(r.Source,'fishball')
        fprintf(['  receiver: %s, %.4f MHz, converter %.3f MSPS, fabric /%d ' ...
                 '-> %.0f kHz, gain %g dB, %s\n'], uri, r.CenterFrequency/1e6, ...
                r.ConverterRate/1e6, r.FabricDecimation, ...
                r.ConverterRate/r.FabricDecimation/1e3, r.Gain, r.Channels);
    else
        fprintf('  receiver: %s, %.4f MHz, %.3f MSPS, gain %g dB, RX1 only\n', ...
                uri, r.CenterFrequency/1e6, r.ConverterRate/1e6, r.Gain);
    end

    if r.Open
        clear cl                      % leave it loaded
        open_system(mdl);
    end
end

function s = chanStr(name)
%CHANSTR  Caller's channel word -> the exact string in RxSource's StringSet.
%
% Map, rather than case-shift. upper() on the first two characters turned
% 'Both' into 'BOth', which set_param rejects with the unhelpfully generic
% "Option specified is not valid" and no hint that the case is the problem.
    switch lower(char(name))
        case 'rx1', s = 'RX1';
        case 'rx2', s = 'RX2';
        otherwise,  s = 'RX1+RX2';
    end
end
