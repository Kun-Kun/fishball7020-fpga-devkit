function hello_board(varargin)
%HELLO_BOARD  Is the board there, and is MATLAB reading it correctly?
%
%   >> hello_board                              % RX1
%   >> hello_board('Channel', 2)                % RX2
%   >> hello_board('CenterFrequency', 868e6)    % where your antenna is useful
%   >> hello_board('Channel', 2, 'Plot', false)
%
% Receive only. Nothing here transmits.
%
% Two things this teaches beyond "it works":
%
%   1. Full scale on this board is +/-2047, not +/-32768. Get it wrong and
%      every absolute level you publish is 24.09 dB low, uniformly, so nothing
%      looks broken. The printout shows both.
%
%   2. THIS BOARD HAS TWO RECEIVERS AND MATLAB CAN ONLY SEE ONE OF THEM.
%      'Channel', 2 does not go through sdrrx, because it cannot: the
%      ADALM-Pluto support package is written for a 1R1T radio and rejects
%      ChannelMapping 2 outright. RX2 is reached through iio_readdev instead.
%      The example prints which path it took, because the difference between
%      the two is the difference between this board and a Pluto.

    p = inputParser;
    p.addParameter('CenterFrequency', 868e6, @isnumeric);
    p.addParameter('SampleRate', 3e6, @isnumeric);
    p.addParameter('Gain', 55, @isnumeric);
    p.addParameter('Channel', 1, @(v) isnumeric(v) && any(v == [1 2]));
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
    if isfield(a,'fw_build'), fprintf('  fw_build    %s\n', a.fw_build); end
    fprintf('  serial      %s\n', fld(a,'hw_serial','(none)'));

    %% 2 - take some samples, by whichever route can reach the channel asked for
    fprintf('\n== capture, RX%d ==\n', r.Channel);
    if r.Channel == 1
        rx = fishball.connect('CenterFrequency', r.CenterFrequency, ...
                              'BasebandSampleRate', r.SampleRate, ...
                              'SamplesPerFrame', 16384, 'Gain', r.Gain);
        cl = onCleanup(@() release(rx));
        rx();                    % the first frame can predate the settings
        xi = rx();
        x  = double(xi);         % abs() refuses a complex int16
        via = 'sdrrx (the ADALM-Pluto support package)';
        cls = class(xi);
        clear cl
    else
        fprintf(['  sdrrx cannot do this. ChannelMapping must be 1 - the ' ...
                 'support package is\n  written for a 1R1T Pluto, and this ' ...
                 'board is 2R2T. Going via iio_readdev.\n']);
        both = fishball.capture2('CenterFrequency', r.CenterFrequency, ...
                                 'SampleRate', r.SampleRate, ...
                                 'Seconds', 16384 / r.SampleRate, ...
                                 'Gain', r.Gain);
        x = both(:, 2);
        via = 'iio_readdev (both receivers captured, RX2 kept)';
        cls = 'double (int16 counts)';
    end

    fprintf('  %d samples at %.3f MSPS, tuned to %.3f MHz, gain %g dB\n', ...
            numel(x), r.SampleRate/1e6, r.CenterFrequency/1e6, r.Gain);
    fprintf('  via %s\n', via);
    fprintf('  %s, peak |sample| = %g\n', cls, max(abs(x)));

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
        % Reuse one window rather than stacking a new figure on every call -
        % this example is meant to be run repeatedly while you move an antenna
        % or change a gain, and twenty identical windows help nobody.
        fig = findobj('Type','figure','Tag','fishball_hello');
        if isempty(fig), fig = figure('Tag','fishball_hello','Color','w');
        else,            fig = fig(1); clf(fig);
        end
        set(fig, 'Name', sprintf('hello board - RX%d', r.Channel));
        ax = axes(fig); %#ok<LAXES>
        plot(ax, (r.CenterFrequency + f)/1e6, db, 'LineWidth', 1);
        grid(ax,'on'); xlabel(ax,'MHz'); ylabel(ax,'dBFS');
        title(ax, sprintf('RX%d  %.3f MHz  %.2f MSPS  gain %g dB', ...
                          r.Channel, r.CenterFrequency/1e6, ...
                          r.SampleRate/1e6, r.Gain));
        ylim(ax, [floorDb-10, max(pk+10, floorDb+30)]);
    end
    fprintf('\n');
end

function v = fld(s,f,d), if isfield(s,f), v = s.(f); else, v = d; end, end
