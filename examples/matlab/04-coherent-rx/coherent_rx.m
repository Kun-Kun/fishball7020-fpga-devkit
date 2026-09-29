function [deg, coh, out] = coherent_rx(varargin)
%COHERENT_RX  RX1 against RX2: phase and coherence. What one receiver cannot do.
%
%   >> coherent_rx                                   % 868 MHz
%   >> coherent_rx('CenterFrequency', 100e6)
%   >> coherent_rx('Blocks', 40)                     % watch it over time
%   >> coherent_rx('TxChannel', 1, 'PadDb', 20)      % give both something to hear
%
% Receive only unless you pass PadDb, which turns on a reference tone.
%
% WHY THIS BOARD CAN DO IT. RX1 and RX2 are inside one AD9361, behind ONE local
% oscillator and ONE sample clock. The phase between them is therefore a
% property of the signal and the cabling - not of two clocks wandering apart,
% which is what you get with two separate radios and why two dongles cannot do
% direction finding without heroics.
%
% READ COHERENCE BEFORE YOU READ PHASE. This is the whole discipline of the
% example. Two independent noise streams correlate to a number that random-
% walks toward zero, and its ANGLE is a perfectly respectable-looking random
% number that a plot will render with total confidence. Coherence near 1 means
% the two inputs are hearing the same thing and the angle means something. Near
% 0 means you are reading noise with a decimal point on it.
%
% WHAT YOU NEED FOR A REAL MEASUREMENT. The same signal into both ports -
% normally a splitter, and two cables of known (ideally equal) length. An
% antenna on one port and a loopback pad on the other, which is a common bench
% state, gives two receivers listening to DIFFERENT things, and the correct
% answer to that is a low coherence. The example says so rather than printing a
% confident angle.
%
% AND IT IS STILL NOT A DIRECTION. A stable phase is a stable phase. Turning it
% into an angle of arrival needs a known baseline, a known geometry, and a
% calibration of the two chains against each other - this board's two receivers
% differ by about 1.5 dB in sensitivity before you start.

    p = inputParser;
    p.addParameter('CenterFrequency', 868e6, @isnumeric);
    p.addParameter('SampleRate', 3e6, @isnumeric);
    p.addParameter('Gain', 55, @isnumeric);
    p.addParameter('Blocks', 20, @isnumeric);
    p.addParameter('BlockSeconds', 0.05, @isnumeric);
    p.addParameter('PadDb', [], @isnumeric);
    p.addParameter('TxChannel', [], @(v) isempty(v) || any(v == [1 2]));
    p.addParameter('TxGain', -40, @isnumeric);
    p.addParameter('Plot', true, @islogical);
    p.parse(varargin{:});
    r = p.Results;

    if r.SampleRate > 4e6
        warning('fishball:coherent:rate', ...
            ['Two channels are clean to about 3 MS/s on this board and drop ' ...
             'samples at 10.\nDropped samples destroy exactly the thing you ' ...
             'are measuring here, and iio_readdev\nreturns every byte you ' ...
             'asked for either way - so it will look fine.']);
    end

    %% optionally give both receivers something to hear
    tx = [];
    if ~isempty(r.TxChannel)
        if isempty(r.PadDb)
            error('fishball:coherent:noPad', ...
                  'PadDb is required when TxChannel is set. See example 03.');
        end
        tone = 0.5 * exp(1j*2*pi*0.05*(0:4095).');
        tx = fishball.safeTransmit(tone, 'PadDb', r.PadDb, 'Gain', r.TxGain, ...
                                   'TxChannel', r.TxChannel, ...
                                   'CenterFrequency', r.CenterFrequency, ...
                                   'BasebandSampleRate', r.SampleRate);
        cl = onCleanup(@() release(tx)); %#ok<NASGU>
        pause(0.5);
    end

    %% capture, in blocks, so we can see whether the phase is STABLE
    degs = zeros(r.Blocks,1); cohs = zeros(r.Blocks,1);
    p1 = zeros(r.Blocks,1);   p2 = zeros(r.Blocks,1);
    fprintf('\n  block   coherence      phase      RX1 rms   RX2 rms\n');
    fprintf(  '  -----   ---------   ----------   -------   -------\n');
    for k = 1:r.Blocks
        x = fishball.capture2('CenterFrequency', r.CenterFrequency, ...
                              'SampleRate', r.SampleRate, ...
                              'Seconds', r.BlockSeconds, 'Gain', r.Gain);
        [degs(k), cohs(k)] = fishball.phase(x);
        p1(k) = rms(x(:,1)); p2(k) = rms(x(:,2));
        if k <= 5 || mod(k, 5) == 0
            fprintf('  %5d   %9.4f   %+8.2f deg   %7.1f   %7.1f\n', ...
                    k, cohs(k), degs(k), p1(k), p2(k));
        end
        if k == 1, last = x; end
    end

    coh = mean(cohs);
    % Average the phase as a VECTOR, never as a number. Angles wrap at +/-180,
    % so the arithmetic mean of -179 and +179 is 0 - which is the opposite of
    % the right answer.
    deg = rad2deg(angle(mean(exp(1j*deg2rad(degs)))));
    spread = rad2deg(std(unwrap(deg2rad(degs))));

    fprintf('\n== over %d blocks ==\n', r.Blocks);
    fprintf('  mean coherence     %.4f\n', coh);
    fprintf('  mean phase         %+.2f deg\n', deg);
    fprintf('  phase spread (1SD) %.2f deg\n', spread);

    verdict(coh, spread);

    out = struct('deg', degs, 'coh', cohs, 'rx1rms', p1, 'rx2rms', p2, ...
                 'meanCoherence', coh, 'meanPhase', deg, 'phaseSpread', spread);
    if r.Plot, plotIt(last, degs, cohs, r); end
    if nargout == 0, clear deg coh out, end
end

function verdict(coh, spread)
    fprintf('\n');
    if coh > 0.9
        fprintf(['  Coherence is high: the two receivers are hearing the same ' ...
                 'thing and the\n  phase above means something. A spread of ' ...
                 '%.2f deg is how stable it is.\n'], spread);
    elseif coh > 0.5
        fprintf(['  Coherence is moderate. Part of what each receiver hears ' ...
                 'is shared and part\n  is not, so the phase is real but ' ...
                 'noisy. More signal, or a narrower band.\n']);
    else
        fprintf(['  COHERENCE IS LOW, so IGNORE the phase above - it is the ' ...
                 'angle of a number\n  that random-walked near zero, and it ' ...
                 'will look just as confident as a real\n  one. The two ' ...
                 'receivers are hearing different things. That is the ' ...
                 'expected\n  answer if one port has an antenna and the ' ...
                 'other a loopback pad; for a real\n  measurement feed BOTH ' ...
                 'from one source through a splitter.\n']);
    end
end

function plotIt(x, degs, cohs, r)
    fig = findobj('Type','figure','Tag','fishball_coh');
    if isempty(fig), fig = figure('Tag','fishball_coh','Color','w');
    else, fig = fig(1); clf(fig); end
    set(fig,'Name','coherent RX');

    ax1 = subplot(3,1,1,'Parent',fig);
    [d1, f] = fishball.spectrum(x(:,1), r.SampleRate);
    d2      = fishball.spectrum(x(:,2), r.SampleRate);
    plot(ax1, (r.CenterFrequency+f)/1e6, d1, (r.CenterFrequency+f)/1e6, d2);
    grid(ax1,'on'); legend(ax1,{'RX1','RX2'},'Location','best');
    xlabel(ax1,'MHz'); ylabel(ax1,'dBFS'); title(ax1,'both receivers');

    ax2 = subplot(3,1,2,'Parent',fig);
    plot(ax2, cohs, '-o'); grid(ax2,'on'); ylim(ax2,[0 1]);
    ylabel(ax2,'coherence'); title(ax2,'read this one first');
    yline(ax2, 0.5, '--');

    ax3 = subplot(3,1,3,'Parent',fig);
    plot(ax3, degs, '-o'); grid(ax3,'on'); ylim(ax3,[-180 180]);
    xlabel(ax3,'block'); ylabel(ax3,'phase, deg');
    title(ax3,'meaningful only where coherence is high');
end
