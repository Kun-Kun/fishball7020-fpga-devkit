function ok = reachable(host, timeoutSec)
%REACHABLE  Does something answer IIOD on this host?
%
% An open port is not proof - board_addr.py makes the same point and for the
% same reason. We ask iio_attr for the context attributes and require it to
% come back cleanly. If the libiio command-line tools are not installed we
% cannot check, and we say "maybe" rather than "no", because refusing to try is
% worse than trying and failing with libiio's own error message.
    if nargin < 2, timeoutSec = 4; end
    if isempty(fishball.internal.which_('iio_attr'))
        ok = true; return
    end
    cmd = sprintf('timeout %d iio_attr -u ip:%s -C hw_model >/dev/null 2>&1', ...
                  timeoutSec, host);
    ok = (system(cmd) == 0);
end
