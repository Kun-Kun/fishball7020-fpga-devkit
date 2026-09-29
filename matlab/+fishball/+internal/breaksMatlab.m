function tf = breaksMatlab(fw)
%BREAKSMATLAB  Will this fw_version string abort MATLAB's connection?
%
% Measured on 2026-09-29 by editing /etc/libiio.ini on a running board and
% restarting iiod between each attempt:
%
%   connects : v2.0   2.0   v2.0.1   v2.0-dirty   v0.39   v0.39-9-gdeadbeef
%   fails    : v2.0-9-g5ae29d94-dirty   v2.0-9-g5ae29d94   v2.0-9-gabcdef
%              v2.0-9-gabcde1          v2.0-9-g5ae29d94-x
%
% So it is the `git describe` shape that breaks it and not the version number.
% v0.39-9-gdeadbeef connects because v0.39 is the version the support package
% expects, so it never builds the warning at all - which is why the test below
% exempts anything starting v0.39.
%
% This is a conservative predicate: it matches the shape that was measured to
% fail and nothing else. It is NOT a reconstruction of MathWorks' parser, which
% I did not establish - an early theory that digits in the hash were the
% trigger was disproved by v2.0-9-gabcdef and v2.0-9-gabcde1 both failing.

    fw = char(strtrim(string(fw)));
    if startsWith(fw, 'v0.39'), tf = false; return, end
    tf = ~isempty(regexp(fw, '-\d+-g[0-9a-fA-F]+', 'once'));
end
