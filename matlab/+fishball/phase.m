function [deg, coh, r] = phase(x1, x2)
%PHASE  Phase and coherence between two receivers.
%
%   [DEG, COH] = FISHBALL.PHASE(X1, X2)
%   [DEG, COH] = FISHBALL.PHASE(X)          X is N-by-2, from fishball.capture2
%
%   DEG   phase of RX1 relative to RX2, degrees
%   COH   coherence, 0 to 1
%
% READ COH BEFORE YOU READ DEG. Two independent noise streams correlate to a
% number that random-walks toward zero, and its ANGLE is a perfectly
% respectable-looking random number. Coherence near 1 means the two inputs are
% hearing the same thing and the angle means something. Near 0 means you are
% reading noise with a decimal point on it. This is the single easiest way to
% fool yourself with two receivers, which is why this function returns both and
% documents them in this order.
%
% The estimator, matching examples/lib/phase_meter.py exactly:
%
%     r    = mean( x1 .* conj(x2) )
%     deg  = angle(r)                  <- taken AFTER the averaging
%     coh  = |r| / sqrt( mean|x1|^2 * mean|x2|^2 )
%
% Averaging the angle instead of the angle of the average is wrong, and wrong
% in a way that looks fine: angles wrap at +/-180, so a phase sitting near the
% wrap averages to something near zero that is not the phase of anything.
%
% What this is NOT. A stable phase is not a direction of arrival. That needs a
% known baseline, a known geometry and a calibration of the two chains against
% each other - this board's two receivers differ by 1.5 dB in sensitivity
% before you start.

    if nargin == 1
        if size(x1,2) ~= 2
            error('fishball:phase:shape', ...
                  'With one argument, X must be N-by-2 (got %d columns).', ...
                  size(x1,2));
        end
        x2 = x1(:,2); x1 = x1(:,1);
    end
    x1 = double(x1(:)); x2 = double(x2(:));
    n = min(numel(x1), numel(x2));
    x1 = x1(1:n); x2 = x2(1:n);

    r = mean(x1 .* conj(x2));
    p1 = mean(abs(x1).^2);
    p2 = mean(abs(x2).^2);
    if p1 == 0 || p2 == 0
        deg = NaN; coh = 0; return
    end
    coh = abs(r) / sqrt(p1 * p2);
    deg = rad2deg(angle(r));
end
