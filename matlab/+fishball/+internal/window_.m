function w = window_(name, n)
%WINDOW_  The same three windows examples/lib/spectrum_engine.py offers, by name.
%
% Defined here from their coefficients rather than taken from Signal Processing
% Toolbox, for two reasons: the spectrum path then works on a base MATLAB with
% only Communications Toolbox, and the coefficients are demonstrably the same
% ones the Python side uses rather than whatever a toolbox decided.
%
% Sidelobe levels, which are the whole reason the choice is offered:
%   rectangular      -13 dB   sharpest main lobe, worst leakage
%   hann             -31 dB
%   blackman-harris  -92 dB   default; what you want to see a small tone
%                             beside a big one
    k = (0:n-1).' / (n - 1);
    switch lower(char(name))
        case {'rect','rectangular','none'}
            w = ones(n, 1);
        case {'hann','hanning'}
            w = 0.5 - 0.5 * cos(2*pi*k);
        case {'blackman-harris','blackmanharris','bh','bh4'}
            a = [0.35875, -0.48829, 0.14128, -0.01168];
            w = a(1) + a(2)*cos(2*pi*k) + a(3)*cos(4*pi*k) + a(4)*cos(6*pi*k);
        otherwise
            error('fishball:window:unknown', ...
                  'Unknown window "%s" - one of rect, hann, blackman-harris.', ...
                  char(name));
    end
end
