function a = context(u)
%CONTEXT  The board's IIO context attributes, as a struct.
%
%   A = FISHBALL.CONTEXT()        resolve the board first
%   A = FISHBALL.CONTEXT(URI)
%
% Field names are the attribute names with '-' and ',' mapped to '_', so
% ad9361-phy,model becomes a.ad9361_phy_model.
%
% This deliberately uses iio_attr rather than the MATLAB support package,
% because it has to work BEFORE the support package will talk to the board -
% that is the whole point of fishball.doctor.

    if nargin < 1 || isempty(u), u = fishball.uri(); end
    if isempty(fishball.internal.which_('iio_attr'))
        error('fishball:context:noTools', ...
              ['iio_attr is not installed. On Debian/Ubuntu:\n' ...
               '    sudo apt install libiio-utils']);
    end
    [st, out] = system(sprintf('timeout 15 iio_attr -u %s -C 2>&1', u));
    if st ~= 0
        error('fishball:context:unreachable', ...
              'No answer from %s:\n%s', u, strtrim(out));
    end

    a = struct();
    for ln = string(splitlines(string(out)))'
        t = strtrim(ln);
        if t == "" || ~contains(t, ':'), continue, end
        k = extractBefore(t, ":");
        v = strtrim(extractAfter(t, ":"));
        k = regexprep(char(k), '[^A-Za-z0-9]', '_');
        if isempty(k) || ~isletter(k(1)), continue, end
        a.(k) = char(v);
    end
end
