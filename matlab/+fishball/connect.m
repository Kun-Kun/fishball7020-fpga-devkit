function rx = connect(varargin)
%CONNECT  A receiver on this board, with the traps already handled.
%
%   RX = FISHBALL.CONNECT()
%   RX = FISHBALL.CONNECT('CenterFrequency',900e6,'BasebandSampleRate',3e6,...)
%
% Name/value pairs are passed through to sdrrx, so anything that object accepts
% works here. The defaults differ from sdrrx's in two places, deliberately:
% manual gain rather than AGC (a measurement wants a known gain), and int16
% output (see FULL SCALE below).
%
% What this adds over calling sdrrx yourself:
%
%   * it resolves the board's address the way every other tool here does
%   * it checks the board is the one this repository is about, before you get a
%     confusing error from somewhere deeper
%   * it turns MATLAB's broken firmware-version failure into a message that
%     says what to do
%
% FULL SCALE. This board's receive converters are 12-bit, sign-extended into
% int16, so full scale is +/-2047 and NOT +/-32768. With OutputDataType int16
% you get those raw counts. With 'double' or 'single' MATLAB divides by 2048
% and full scale is +/-1.0 - measured, not assumed: the same signal read 5
% counts and 0.00244141, and 5/0.00244141 = 2048 exactly. Transmit is different
% again and uses the full +/-32767. Mixing the receive conventions is 66 dB;
% mixing receive with transmit is 24.09 dB. fishball.spectrum takes a fullScale
% argument for exactly this reason.
%
% RETUNING. Setting a property on a running object does NOT reach the chip.
% Measured: .Gain changed from 10 to 60 on a locked object produced six
% identical frames, while the same gains applied at construction gave rms 0.83
% through 27.63. Call release(rx) and build a new one, or use the helper
%
%     rx = fishball.connect('Gain',40);      % not rx.Gain = 40
%
% This is the same trap pyadi-iio has, where the fix is rx_destroy_buffer().
%
% See also FISHBALL.DOCTOR, FISHBALL.CAPTURE2, FISHBALL.SPECTRUM.

    p = inputParser; p.KeepUnmatched = true;
    p.addParameter('URI', '', @(x) ischar(x) || isstring(x));
    p.addParameter('SkipChecks', false, @islogical);
    p.parse(varargin{:});
    u = fishball.uri(p.Results.URI);

    if ~p.Results.SkipChecks
        fishball.internal.assertBoard(u);
    end

    defaults = {'CenterFrequency', 900e6, ...
                'BasebandSampleRate', 3e6, ...
                'SamplesPerFrame', 16384, ...
                'GainSource', 'Manual', ...
                'Gain', 40, ...
                'OutputDataType', 'int16'};
    args = mergeArgs(defaults, p.Unmatched);

    if isempty(which('sdrrx'))
        error('fishball:connect:noSupportPackage', ...
              ['sdrrx was not found, so the ADALM-Pluto support package is ' ...
               'not installed.\n' ...
               'Install it from the Add-On Explorer, or work offline with ' ...
               'fishball.readSigMF on a capture\nmade by ' ...
               'tools/sigmf-capture.py - that path needs no support package.']);
    end

    % MathWorks' own firmware warning is accurate but it ends by telling you
    % to open the Hardware Setup App and "switch the firmware version to
    % 0.39". Doing that would write a Zynq-7010 ADALM-Pluto image onto this
    % Zynq-7020 board. Suppress theirs, say the useful half ourselves, once.
    st = warning('off', 'plutoradio:sysobj:FirmwareIncompatible');
    restore = onCleanup(@() warning(st));
    fishball.internal.firmwareNote();

    try
        rx = sdrrx('Pluto', 'RadioID', u, args{:});
        % setup() here, not on the caller's first rx(), because the warning is
        % raised when the object CONNECTS and that happens at first use - by
        % which time the onCleanup above has already put the warning state
        % back and the caller sees it anyway. Connecting inside this function
        % is the only way the suppression can cover it. It also moves the
        % several-second connection delay to a predictable place.
        setup(rx);
    catch e
        rethrow(fishball.internal.explain(e, u));
    end
end

function out = mergeArgs(defaults, unmatched)
    given = fieldnames(unmatched);
    out = {};
    for k = 1:2:numel(defaults)
        if ~any(strcmpi(defaults{k}, given))
            out(end+1:end+2) = defaults(k:k+1); %#ok<AGROW>
        end
    end
    for k = 1:numel(given)
        out(end+1:end+2) = {given{k}, unmatched.(given{k})}; %#ok<AGROW>
    end
end
