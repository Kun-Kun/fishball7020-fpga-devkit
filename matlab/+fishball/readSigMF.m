function [x, meta] = readSigMF(path, varargin)
%READSIGMF  Read a capture written by tools/sigmf-capture.py.
%
%   [X, META] = FISHBALL.READSIGMF('capture.sigmf-meta')
%   [X, META] = FISHBALL.READSIGMF('capture', 'Normalize', true)
%
% This is the route that needs NO support package: base MATLAB plus, for the
% analysis, Communications Toolbox. If you cannot install a 1 GB add-on, or you
% want to work on a capture made somewhere else, this is the door.
%
%   X       complex column vector, or one column per channel
%   META    the sidecar, plus SampleRate / CenterFrequency / FullScale pulled
%           out as numbers because those three are what you always want
%
% Name/value:
%   'Normalize'  false (default) returns raw converter counts as double.
%                true divides by META.FullScale so full scale is +/-1.0.
%
% ON FULL SCALE, because this is where people lose 24 dB. These converters are
% 12-bit sign-extended into int16, so full scale is the sidecar's
% fishball:full_scale - 2047 - and NOT 32768. The sidecar carries the number so
% that no reader has to know this; use it rather than a constant of your own.
% Transmit is the other way round and uses the full +/-32767.

    p = inputParser;
    p.addParameter('Normalize', false, @islogical);
    p.parse(varargin{:});

    [metaPath, dataPath] = resolvePaths(path);
    raw = fileread(metaPath);
    meta = jsondecode(raw);
    g = meta.global;

    meta.SampleRate     = getnum(g, 'core_sample_rate', NaN);
    meta.CenterFrequency = NaN;
    if isfield(meta,'captures') && ~isempty(meta.captures)
        c = meta.captures(1);
        if isstruct(c) && isfield(c,'core_frequency'), meta.CenterFrequency = c.core_frequency; end
    end
    meta.FullScale = getnum(g, 'fishball_full_scale', 2047);

    dt = '';
    if isfield(g,'core_datatype'), dt = g.core_datatype; end
    if ~strcmp(dt, 'ci16_le')
        error('fishball:readSigMF:datatype', ...
              ['Only ci16_le is supported here; this file says "%s".\n' ...
               'That is what tools/sigmf-capture.py writes.'], dt);
    end

    f = fopen(dataPath, 'r', 'ieee-le');
    if f < 0, error('fishball:readSigMF:noData', 'Cannot open %s', dataPath); end
    cl = onCleanup(@() fclose(f));
    v = fread(f, Inf, 'int16=>double');

    nch = channelCount(g);
    if mod(numel(v), 2*nch) ~= 0
        warning('fishball:readSigMF:ragged', ...
                ['%s holds %d int16s, not a whole number of %d-channel ' ...
                 'complex samples. Truncating.'], dataPath, numel(v), nch);
        v = v(1 : floor(numel(v)/(2*nch)) * 2*nch);
    end
    v = reshape(v, 2*nch, []).';
    x = complex(v(:, 1:2:end), v(:, 2:2:end));

    if p.Results.Normalize
        x = x ./ meta.FullScale;
        meta.Normalized = true;
    else
        meta.Normalized = false;
    end
end

function n = channelCount(g)
% The recorder says "RX1", "RX2" or "RX1+RX2" in core:hw and core:description.
    n = 1;
    s = '';
    if isfield(g,'core_hw'), s = [s ' ' g.core_hw]; end
    if isfield(g,'core_description'), s = [s ' ' g.core_description]; end
    if contains(s, 'RX1+RX2') || contains(lower(s), 'both'), n = 2; end
end

function v = getnum(s, f, dflt)
    if isfield(s, f), v = double(s.(f)); else, v = dflt; end
end

function [m, d] = resolvePaths(path)
    path = char(path);
    if endsWith(path, '.sigmf-meta')
        m = path; d = [path(1:end-numel('sigmf-meta')) 'sigmf-data'];
    elseif endsWith(path, '.sigmf-data')
        d = path; m = [path(1:end-numel('sigmf-data')) 'sigmf-meta'];
    else
        m = [path '.sigmf-meta']; d = [path '.sigmf-data'];
    end
    if ~isfile(m), error('fishball:readSigMF:noMeta', 'No sidecar at %s', m); end
    if ~isfile(d), error('fishball:readSigMF:noData', 'No data at %s', d); end
end
