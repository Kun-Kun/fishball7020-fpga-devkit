function c = qam(order)
%QAM  Square QAM constellation at unit mean power, shared by modulator and EVM.
%
%   C = FISHBALL.QAM(4)    QPSK
%   C = FISHBALL.QAM(16)   16-QAM
%
% One definition used by both ends, which is the point: in the GNU Radio
% examples this is examples/lib/qam.py and it exists so the thing the modulator
% builds from and the thing the EVM meter measures against cannot drift apart.
%
% Unit MEAN power, not unit peak: levels are divided by
% sqrt(2 * mean(level^2)), the 2 accounting for the two dimensions. That makes
% EVM comparable between orders, which it is not if you normalise by the peak.

    m = round(sqrt(order));
    if m^2 ~= order || mod(m,2) ~= 0
        error('fishball:qam:order', ...
              'order must be a square with an even root (4, 16, 64, 256); got %g', ...
              order);
    end
    lv = -(m-1) : 2 : (m-1);
    lv = lv / sqrt(2 * mean(lv.^2));
    [I, Q] = meshgrid(lv, lv);
    c = I(:) + 1j*Q(:);
end
