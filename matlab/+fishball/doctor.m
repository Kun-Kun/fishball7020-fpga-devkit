function ok = doctor(varargin)
%DOCTOR  Can this MATLAB talk to this board? Answer in a few seconds.
%
%   fishball.doctor            check and print
%   ok = fishball.doctor       ... and return true if everything passed
%
% In the spirit of ./devkit doctor: every check here is a failure that has
% already cost somebody time, and each one says what to do rather than only
% what is wrong.

    p = inputParser;
    p.addParameter('URI', '', @(x) ischar(x) || isstring(x));
    p.parse(varargin{:});

    fails = strings(0); warns = strings(0);
    line = @(s) fprintf('%s\n', s);

    line(''); line('== MATLAB ==');
    [fails, warns] = check('MATLAB release', true, version('-release'), fails, warns);

    need = {'Communications Toolbox', true; ...
            'DSP System Toolbox',    false; ...
            'Signal Processing Toolbox', false; ...
            'Simulink',              false};
    v = ver; have = string({v.Name});
    for k = 1:size(need,1)
        nm = need{k,1}; required = need{k,2};
        got = any(have == nm);
        [fails, warns] = check(nm, ternary(got, true, ternary(required, false, [])), ...
                               ternary(got, 'installed', 'not installed'), ...
                               fails, warns);
    end
    % HDL Coder is called out by name because `ver` listing it is not the same
    % as it being licensed, and people reasonably assume it is.
    if any(have == "HDL Coder")
        [fails, warns] = check('HDL Coder', [], 'present - but check the licence', fails, warns);
    end

    line(''); line('== support package ==');
    sp = ~isempty(which('sdrrx'));
    [fails, warns] = check('ADALM-Pluto support package', ternary(sp, true, []), ...
        ternary(sp, 'sdrrx available', ...
        'not installed - the SigMF path still works, live radio does not'), fails, warns);

    line(''); line('== host tools ==');
    for t = {'iio_attr','iio_readdev','python3'}
        p_ = fishball.internal.which_(t{1});
        [fails, warns] = check(t{1}, ~isempty(p_), ...
            ternary(~isempty(p_), p_, 'missing - apt install libiio-utils'), fails, warns);
    end

    line(''); line('== board ==');
    u = '';
    try
        u = fishball.uri(p.Results.URI);
        [fails, warns] = check('address', true, u, fails, warns);
    catch e
        [fails, warns] = check('address', false, e.message, fails, warns);
        ok = finish(fails, warns); return
    end

    try
        a = fishball.context(u);
    catch e
        [fails, warns] = check('reachable', false, e.message, fails, warns);
        ok = finish(fails, warns); return
    end

    model = fld(a,'hw_model','');
    isOurs = contains(model,'FISH Ball PlutoSDR') && contains(model,'Z7020') ...
             && contains(model,'AD9361');
    [fails, warns] = check('hw_model', ternary(isOurs, true, []), model, fails, warns);

    fw = fld(a,'fw_version','');
    bad = ~isempty(fw) && fishball.internal.breaksMatlab(fw);
    [fails, warns] = check('fw_version usable by MATLAB', ~bad, ...
        ternary(bad, sprintf('%s - a git describe here aborts the connection', fw), fw), ...
        fails, warns);
    if isfield(a,'fw_build')
        [fails, warns] = check('fw_build', [], a.fw_build, fails, warns);
    end

    if bad
        line('');
        line('   fw_version carries a `git describe`, and MATLAB''s support package');
        line('   cannot format its own "incompatible firmware" warning when it sees one,');
        line('   so building that warning throws and the connection dies. On the board:');
        line('');
        line('       /usr/local/sbin/fishball-identity && systemctl restart iiod');
        line('');
        line('   which writes fw_version=<release> and fw_build=<describe>. Never accept');
        line('   MATLAB''s offer to update the firmware - that image is for a Zynq-7010.');
    end

    ok = finish(fails, warns);
    if nargout == 0, clear ok, end
end

function [f, w] = check(name, state, detail, f, w)
    % state: true PASS, false FAIL, [] INFO/SKIP - counted as neither.
    if isempty(state),      tag = 'INFO';
    elseif state,           tag = 'PASS';
    else,                   tag = 'FAIL'; f(end+1) = string(name);
    end
    fprintf('  %-4s  %-34s %s\n', tag, name, detail);
end

function ok = finish(fails, warns) %#ok<INUSD>
    fprintf('\n');
    if isempty(fails)
        fprintf('OK - MATLAB can use this board.\n');
        ok = true;
    else
        fprintf('%d check(s) failed: %s\n', numel(fails), strjoin(fails, ', '));
        ok = false;
    end
end

function v = fld(s,f,d), if isfield(s,f), v = s.(f); else, v = d; end, end
function r = ternary(c,a,b), if c, r = a; else, r = b; end, end
