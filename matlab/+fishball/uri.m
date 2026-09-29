function u = uri(override)
%URI  The libiio URI for this board, resolved the way every other tool here does.
%
%   U = FISHBALL.URI()      resolve, honouring $BOARD and $SDR_URI
%   U = FISHBALL.URI(S)     use S, after normalising it to "ip:<host>"
%
% There is one address contract in this repository and it lives in
% tools/board_addr.py, whose documented order is:
%
%   1. an address passed in explicitly
%   2. $BOARD, or $SDR_URI
%   3. fishball.local            this repo's default hostname
%   4. Fishball7020.local, pluto.local
%   5. 192.168.2.1               the USB gadget, which never moves
%
% Rather than reimplement that here and let the two drift, this shells out to
% it. If python3 is not on the path we fall back to the same defaults in the
% same order, so MATLAB still works on a machine set up only for MATLAB.
%
% Note that board_addr.py does not trust an open port: it sends VERSION to
% 30431 and requires a reply, because 192.168.2.1 is a common private address
% and a VPN can carry it somewhere else entirely.

    if nargin >= 1 && ~isempty(override)
        u = normalise(override);
        return
    end

    for v = ["SDR_URI", "BOARD"]
        e = getenv(v);
        if ~isempty(e), u = normalise(e); return, end
    end

    root = fishball.repoRoot();
    script = fullfile(root, 'tools', 'board_addr.py');
    if isfile(script)
        [st, out] = system(sprintf('python3 %s --uri 2>/dev/null', ...
                                   escape(script)));
        out = strtrim(out);
        if st == 0 && startsWith(out, 'ip:')
            u = out; return
        end
    end

    % board_addr.py unavailable or found nothing. Same candidates, same order.
    for h = ["fishball.local", "Fishball7020.local", "pluto.local", "192.168.2.1"]
        if fishball.internal.reachable(h)
            u = "ip:" + h; u = char(u); return
        end
    end
    error('fishball:uri:notFound', ...
          ['No board answered on fishball.local, Fishball7020.local, ' ...
           'pluto.local or 192.168.2.1.\nSet BOARD=<address> if yours is ' ...
           'elsewhere, or pass one in.']);
end

function u = normalise(s)
    s = char(strtrim(string(s)));
    if startsWith(s, 'ip:') || startsWith(s, 'usb:') || startsWith(s, 'local:')
        u = s;
    else
        u = ['ip:' s];
    end
end

function s = escape(p)
    s = ['"' strrep(p, '"', '\"') '"'];
end
