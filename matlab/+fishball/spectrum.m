function [db, f] = spectrum(x, fs, varargin)
%SPECTRUM  Power spectrum in dBFS, defined the same way the Python tools define it.
%
%   [DB, F] = FISHBALL.SPECTRUM(X, FS)
%   [DB, F] = FISHBALL.SPECTRUM(X, FS, 'FullScale', 2047, 'Window', 'blackman-harris')
%
%   DB   one column per column of X, dBFS, fftshifted so F is ascending
%   F    frequency axis in Hz, centred on 0 (add the LO for absolute)
%
% This is a port of examples/lib/spectrum_engine.py and it is deliberately the
% same arithmetic, so a level measured in MATLAB and the same level measured in
% the GNU Radio examples agree rather than nearly agree:
%
%     p  = |fftshift(fft(x .* w))|^2 / (sum(w)^2 * fullScale^2)
%     dB = 10*log10(p + 1e-30)
%
% The window's own gain is divided back out, which is what makes a full-scale
% tone read 0 dBFS whichever window you choose - so the traces stay comparable
% when you change it. The 1e-30 stops an empty bin becoming -Inf and taking the
% autoscale of whatever you plot it with.
%
% FULLSCALE IS NOT OPTIONAL TO GET RIGHT. Its default here is 2047, which is
% correct for the int16 output of fishball.connect and for a capture read by
% fishball.readSigMF without 'Normalize'. If you normalised, or you are holding
% doubles straight out of sdrrx (which divides by 2048), pass 1.0. Getting this
% wrong moves every absolute level by 66 dB and moves nothing else, so the plot
% still looks entirely reasonable.

    p = inputParser;
    p.addParameter('FullScale', 2047, @(v) isnumeric(v) && isscalar(v) && v > 0);
    p.addParameter('Window', 'blackman-harris', @(s) ischar(s) || isstring(s));
    p.parse(varargin{:});

    if isvector(x), x = x(:); end
    n = size(x, 1);
    w = fishball.internal.window_(p.Results.Window, n);
    norm = sum(w)^2 * p.Results.FullScale^2;

    X = fftshift(fft(double(x) .* w, [], 1), 1);
    pw = (real(X).^2 + imag(X).^2) / norm;
    db = 10 * log10(pw + 1e-30);

    if nargout > 1
        f = ((0:n-1).' - floor(n/2)) * (fs / n);
    end
end
