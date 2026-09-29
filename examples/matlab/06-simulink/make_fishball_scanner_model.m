function mdl = make_fishball_scanner_model(varargin)
%MAKE_FISHBALL_SCANNER_MODEL  Build fishball_scanner.slx: the model drives the radio.
%
%   >> make_fishball_scanner_model('Open', true)
%   >> make_fishball_scanner_model('StartFrequency', 400e6, 'StopFrequency', 450e6)
%
% WHAT THIS SHOWS THAT fishball_rx.slx DOES NOT. There, the radio's settings
% live in the block dialog and never change while the model runs. Here they are
% INPUT PORTS, so the model itself retunes - a staircase walks the local
% oscillator across a band, one look at a time, and the spectrum window
% redraws at each step. That is a scanner, and it is a few blocks.
%
% The block is fishball.RxSource with ControlPorts = 'all', which exposes six:
%
%     Fc        Hz          the local oscillator
%     gain1     dB          RX1 gain
%     gain2     dB          RX2 gain, separately - the two receivers on this
%                           board differ by about 1.5 dB, so one shared number
%                           is a compromise rather than a setting
%     BW        Hz          the analogue channel filter
%     gainMode  0..3        0 manual, 1 AGC slow, 2 AGC fast, 3 hybrid
%     RFport    1..12       1 A Balanced ... 10/11 TX Monitor 1/2
%
% NaN ON A PORT MEANS "LEAVE THIS ALONE". Two of the six are wired to NaN
% constants here, so those keep whatever the dialog set and the model only
% commands what it actually cares about. Without that you would have to wire a
% correct constant to all six to drive one.
%
% PACE THESE SLOWLY. Each change that is actually a change costs an iio_attr
% round trip - roughly 10-30 ms - against a frame of 14 ms at 288 kHz. A value
% is only pushed WHEN IT CHANGES, so a constant port is free; a port that moves
% every frame will starve the stream. The dwell below is 20 frames.
%
% Receive only. Nothing here transmits.

    p = inputParser;
    p.addParameter('Name', 'fishball_scanner', @(s) ischar(s) || isstring(s));
    p.addParameter('StartFrequency',  88e6,   @isnumeric);
    p.addParameter('StopFrequency',  108e6,   @isnumeric);
    p.addParameter('ConverterRate',   2.304e6, @isnumeric);
    p.addParameter('FabricDecimation', 8, @(v) any(v == [1 8]));
    p.addParameter('SamplesPerFrame', 4096, @isnumeric);
    p.addParameter('DwellFrames', 20, @(v) isnumeric(v) && v >= 1);
    p.addParameter('Gain1', 55, @isnumeric);
    p.addParameter('Gain2', 55, @isnumeric);
    p.addParameter('RFBandwidth', 0, @isnumeric);   % 0 -> match the look
    p.addParameter('Channels', 'RX1', @(s) any(strcmpi(s,{'RX1','RX2','Both'})));
    p.addParameter('Open', false, @islogical);
    p.addParameter('SaveTo', '', @(s) ischar(s) || isstring(s));
    p.parse(varargin{:});
    r = p.Results;
    mdl = char(r.Name);

    baseband  = r.ConverterRate / r.FabricDecimation;
    frameTime = r.SamplesPerFrame / baseband;
    dwell     = r.DwellFrames * frameTime;

    % Step by one look, so the sweep TILES the band instead of sampling it.
    % Stepping by a round 1 MHz with 288 kHz of bandwidth would skip 70% of
    % the spectrum and look like a scan that found nothing.
    steps = r.StartFrequency : baseband : r.StopFrequency;
    if numel(steps) < 2
        error('fishball:scanner:span', ...
              'Span %.3f MHz is narrower than one %.0f kHz look.', ...
              (r.StopFrequency - r.StartFrequency)/1e6, baseband/1e3);
    end
    bw = r.RFBandwidth; if bw == 0, bw = baseband; end

    uri = fishball.uri();
    bdclose(mdl);
    new_system(mdl);
    cl = onCleanup(@() bdclose(mdl));

    % ---- the receiver, with its levers exposed ---------------------------
    rxBlk = [mdl '/Fishball RX'];
    add_block('simulink/User-Defined Functions/MATLAB System', rxBlk, ...
              'Position', [330 90 520 290], 'System', 'fishball.RxSource');
    set_param(rxBlk, ...
        'ControlPorts',       'all', ...
        'CenterFrequency',    num2str(r.StartFrequency), ...
        'BasebandSampleRate', num2str(baseband), ...
        'FabricDecimation',   num2str(r.FabricDecimation), ...
        'SamplesPerFrame',    num2str(r.SamplesPerFrame), ...
        'GainSource',         'Manual', ...
        'Gain',               num2str(r.Gain1), ...
        'ChannelMapping',     chanStr(r.Channels));
    % Required, not a preference - the block reaches the radio with system().
    set_param(rxBlk, 'SimulateUsing', 'Interpreted execution');

    % ---- the sweep -------------------------------------------------------
    swp = [mdl '/sweep'];
    add_block('simulink/Sources/Repeating Sequence Stair', swp, ...
              'Position', [60 96 150 144]);
    % ONE RATE IN THE MODEL. The staircase ticks at the frame rate and each
    % frequency is REPEATED for the dwell, rather than the staircase ticking
    % slowly at its own rate. Two rates means Simulink must find a common step,
    % and a dwell written as a rounded decimal is not an exact multiple of
    % 4096/288000 - it fails to compile with "the computed fixed step size is
    % 1000000 times smaller than all the discrete sample times", which is a
    % true statement about a problem you did not know you had.
    %
    % Repeating costs nothing: the block pushes a value only when it CHANGES,
    % so the 19 identical frames after each step are free.
    set_param(swp, ...
        'OutValues', sprintf('repelem(%.10g:%.10g:%.10g, %d)', ...
                             r.StartFrequency, baseband, r.StopFrequency, ...
                             r.DwellFrames), ...
        'tsamp', sprintf('%.10g/%.10g', r.SamplesPerFrame, baseband), ...
        'OutDataTypeStr', 'double');

    % ---- the levers held still -------------------------------------------
    % NaN = leave alone. gainMode and RFport keep what the dialog set, so the
    % model commands four of the six and says nothing about the other two.
    fixed = { 'gain1',    r.Gain1,  [60 166 150 194]
              'gain2',    r.Gain2,  [60 216 150 244]
              'BW',       bw,       [60 266 150 294]
              'gainMode', NaN,      [60 316 150 344]
              'RFport',   NaN,      [60 366 150 394] };
    for k = 1:size(fixed,1)
        b = [mdl '/' fixed{k,1}];
        add_block('simulink/Sources/Constant', b, 'Position', fixed{k,3});
        set_param(b, 'Value', num2str(fixed{k,2}, '%.9g'), ...
                     'SampleTime', 'inf');   % constant: never a second rate
    end

    add_line(mdl, 'sweep/1',    'Fishball RX/1', 'autorouting', 'on');
    add_line(mdl, 'gain1/1',    'Fishball RX/2', 'autorouting', 'on');
    add_line(mdl, 'gain2/1',    'Fishball RX/3', 'autorouting', 'on');
    add_line(mdl, 'BW/1',       'Fishball RX/4', 'autorouting', 'on');
    add_line(mdl, 'gainMode/1', 'Fishball RX/5', 'autorouting', 'on');
    add_line(mdl, 'RFport/1',   'Fishball RX/6', 'autorouting', 'on');

    % ---- what came back --------------------------------------------------
    load_system('dspsnks4');
    add_block('dspsnks4/Spectrum Analyzer', [mdl '/Spectrum Analyzer'], ...
              'Position', [640 105 700 175]);
    add_line(mdl, 'Fishball RX/1', 'Spectrum Analyzer/1', 'autorouting', 'on');

    % [rssi1, rssi2, AD9361 degC, applied gain] - read back from the chip, so
    % it is what the radio DID, not what the model asked for.
    add_block('simulink/Sinks/Display', [mdl '/radio status'], ...
              'Position', [640 220 760 280]);
    add_line(mdl, 'Fishball RX/2', 'radio status/1', 'autorouting', 'on');

    % Where the sweep currently is, in MHz, so the spectrum has an x origin.
    add_block('simulink/Math Operations/Gain', [mdl '/to MHz'], ...
              'Position', [200 105 230 135], 'Gain', '1e-6');
    add_block('simulink/Sinks/Display', [mdl '/tuned MHz'], ...
              'Position', [640 40 740 70]);
    add_line(mdl, 'sweep/1',  'to MHz/1',    'autorouting', 'on');
    add_line(mdl, 'to MHz/1', 'tuned MHz/1', 'autorouting', 'on');

    % ---- solver ----------------------------------------------------------
    % One full sweep, then stop - an endless scan gives you nothing to compare.
    set_param(mdl, 'SolverType', 'Fixed-step', 'Solver', 'FixedStepDiscrete', ...
                   'FixedStep', 'auto', ...
                   'StopTime', num2str(numel(steps) * dwell, '%.9g'));

    if isempty(r.SaveTo)
        out = fullfile(fileparts(mfilename('fullpath')), [mdl '.slx']);
    else
        out = char(r.SaveTo);
    end
    save_system(mdl, out);

    fprintf('  wrote %s\n', out);
    fprintf(['  %s  %.1f - %.1f MHz in %d looks of %.0f kHz, ' ...
             '%.0f ms each, one sweep = %.1f s\n'], uri, ...
            r.StartFrequency/1e6, steps(end)/1e6, numel(steps), ...
            baseband/1e3, dwell*1e3, numel(steps)*dwell);

    if r.Open
        clear cl
        open_system(mdl);
    end
end

function s = chanStr(name)
%CHANSTR  Caller's channel word -> the exact string in RxSource's StringSet.
    switch lower(char(name))
        case 'rx1', s = 'RX1';
        case 'rx2', s = 'RX2';
        otherwise,  s = 'RX1+RX2';
    end
end
