function r = repoRoot()
%REPOROOT  The devkit checkout this package lives in.
%   matlab/+fishball/repoRoot.m  ->  two levels up is the repo root.
    here = fileparts(mfilename('fullpath'));      % .../matlab/+fishball
    r = fileparts(fileparts(here));
end
