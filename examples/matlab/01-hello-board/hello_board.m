function hello_board(varargin)
%HELLO_BOARD  Is the board there, and is MATLAB reading it correctly?
%
%   # run from: the repo root
%   >> addpath matlab
%   >> hello_board
%   >> hello_board('CenterFrequency', 868e6)     % where your antenna is
%
% Receive only. Nothing here transmits.
%
% This is the "is it alive" example, and it is also where the one trap that
% silently corrupts every level you will ever publish gets taught: full scale
% on this board is +/-2047, not +/-32768. See the printout.

    p = inputParser;
    p.addParameter('CenterFrequency', 868e6, @isnumeric);
    p.addParameter('SampleRate', 3e6, @isnumeric);
    p.addParameter('Gain', 55, @isnumeric);
    p.addParameter('Plot', true, @islogical);
    p.parse(varargin{:});
    r = p.Results;

    %% 1 - who is this?
    u = fishball.uri();
    a = fishball.context(u);
    fprintf('\n== the board ==\n');
    fprintf('  address     %s\n', u);
    fprintf('  hw_model    %s\n', fld(a,'hw_model','(none)'));
    fprintf('  fw_version  %s\n', fld(a,'fw_version','(none)'));
    if isfield(a,'fw_build')
        fprintf('  fw_build    %s\n', a.fw_build);
    end
    fprintf('  serial      %s\n', fld(a,'hw_serial','(none)'));

    %% 2 - take some samples
    fprintf('\n== capture ==\n');
    rx = fishball.connect('CenterFrequency', r.CenterFrequency, ...
                          'BasebandSampleRate', r.SampleRate, ...
                          'SamplesPerFrame', 16384, ...
                          'Gain', r.Gain);
    cl = onCleanup(@() release(rx));
    rx();                       % the first frame can predate the settings
    xi = rx();                  % keep the int16 so we can show what it is
    x  = double(xi);            % abs() and friends refuse a complex int16

    fprintf('  %d samples at %.3f MSPS, tuned to %.3f MHz, gain %g dB\n', ...
            numel(x), r.SampleRate/1e6, r.CenterFrequency/1e6, r.Gain);
    fprintf('  class %s, peak |sample| = %g\n', class(xi), max(abs(x)));

    %% 3 - the trap
    fullScale = 2047;
    pkRight = 20*log10(max(abs(x)) / fullScale);
    pkWrong = 20*log10(max(abs(x)) / 32768);
    fprintf('\n== full scale ==\n');
    fprintf('  peak, against 2047  (right) : %7.2f dBFS\n', pkRight);
    fprintf('  peak, against 32768 (wrong) : %7.2f dBFS   <- %.2f dB low\n', ...
            pkWrong, pkRight - pkWrong);
    fprintf(['  The converters are 12-bit sign-extended into int16. Dividing\n' ...
             '  by 32768 makes every absolute level %.2f dB low - uniformly,\n' ...
             '  so nothing looks wrong. Ratios (SNR, EVM) are unaffected.\n'], ...
            pkRight - pkWrong);

    %% 4 - a spectrum
    [db, f] = fishball.spectrum(x, r.SampleRate, 'FullScale', fullScale);
    [pk, ix] = max(db);
    floorDb = median(db);
    fprintf('\n== spectrum ==\n');
    fprintf('  noise floor (median bin)  %7.2f dBFS\n', floorDb);
    fprintf('  strongest bin             %7.2f dBFS at %+.4f MHz -> %.4f MHz\n', ...
            pk, f(ix)/1e6, (r.CenterFrequency + f(ix))/1e6);
    fprintf('  that is %.1f dB above the floor\n', pk - floorDb);

    if r.Plot
        figure('Name','hello_board','Color','w');
        plot((r.CenterFrequency + f)/1e6, db, 'LineWidth', 1);
        grid on; xlabel('MHz'); ylabel('dBFS');
        title(sprintf('%.3f MHz, %.2f MSPS, gain %g dB', ...
                      r.CenterFrequency/1e6, r.SampleRate/1e6, r.Gain));
        ylim([floorDb-10, max(pk+10, floorDb+30)]);
    end
    fprintf('\n');
end

function v = fld(s,f,d), if isfield(s,f), v = s.(f); else, v = d; end, end
