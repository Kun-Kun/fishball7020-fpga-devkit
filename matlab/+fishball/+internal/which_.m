function p = which_(prog)
%WHICH_  Path to an external program, or '' if it is not installed.
    [st, out] = system(['command -v ' prog ' 2>/dev/null']);
    if st == 0, p = strtrim(out); else, p = ''; end
end
