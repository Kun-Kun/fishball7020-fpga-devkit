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
% things - docs/img/make_*_svg.py, docs/course/make_print_html.py.
%
% RX1 ONLY. The Simulink block is the same support package as sdrrx and has the
% same limit: ChannelMapping must be 1. There is no Simulink path to RX2. If
% you need the second receiver, that is MATLAB and fishball.capture2 - see
% example 04.

    p = inputParser;
    p.addParameter('Name', 'fishball_rx', @(s) ischar(s) || isstring(s));
    p.addParameter('CenterFrequency', 90.4e6, @isnumeric);
    p.addParameter('SampleRate', 2.304e6, @isnumeric);
    p.addParameter('Gain', 45, @isnumeric);
    p.addParameter('FrameLength', 4096, @isnumeric);
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
        'BasebandSampleRate', num2str(r.SampleRate), ...
        'GainSource',         'Manual', ...
        'Gain',               num2str(r.Gain), ...
        'SamplesPerFrame',    num2str(r.FrameLength), ...
        'OutputDataType',     'int16');

    % ---- somewhere to look at it ----------------------------------------
    load_system('dspsnks4');
    saBlk = [mdl '/Spectrum Analyzer'];
    add_block('dspsnks4/Spectrum Analyzer', saBlk, 'Position', [420 95 480 165]);

    add_line(mdl, 'Pluto Receiver/1', 'Spectrum Analyzer/1', ...
             'autorouting', 'on');

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
    fprintf('  receiver: %s, %.4f MHz, %.3f MSPS, gain %g dB, RX1\n', ...
            uri, r.CenterFrequency/1e6, r.SampleRate/1e6, r.Gain);

    if r.Open
        clear cl                      % leave it loaded
        open_system(mdl);
    end
end
