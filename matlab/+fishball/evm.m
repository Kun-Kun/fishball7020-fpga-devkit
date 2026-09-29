function [pct, out] = evm(sym, order, varargin)
%EVM  Error vector magnitude, defined exactly as examples/lib/evm_meter.py defines it.
%
%   PCT = FISHBALL.EVM(SYM, 4)          QPSK
%   [PCT, OUT] = FISHBALL.EVM(SYM, 16)  16-QAM, plus the decided reference
%
% SYM is recovered symbols - AFTER the matched filter, the symbol synchroniser
% and the carrier loop. Feed it anything earlier and you are measuring your own
% receiver, which is a fine thing to do but is not what EVM means.
%
% NORMALISATION, which is the part that is easy to get subtly wrong and which
% this deliberately copies rather than reinvents. EVM divides the error by the
% RMS of the DECIDED REFERENCE SYMBOLS, and the measured symbols are scaled so
% their mean power matches those same reference symbols. Scaling to the ideal
% constellation's unit power instead is not the same thing: for a short block
% the decided symbols' own RMS differs from the ideal set's by about
% std(P)/sqrt(n), and that mismatch shows up as error. It puts a floor under
% the reading that no amount of improving the link removes, and which somebody
% will eventually mistake for a real impairment.
%
%   OUT.evm        the same number as PCT
%   OUT.evmGainFixed  EVM after one complex tap of least-squares gain/phase
%                     correction, g = <ref,y>/<ref,ref>. The difference between
%                     the two says how much of your error was a fixed gain or
%                     rotation rather than noise.
%   OUT.ref        the decided reference symbols
%   OUT.scaled     the measured symbols on the reference's scale

    p = inputParser;
    p.addParameter('GainCorrect', true, @islogical);
    p.parse(varargin{:});

    y = double(sym(:));
    r = sqrt(mean(abs(y).^2));
    if r <= 0
        pct = NaN; out = struct('evm',NaN,'evmGainFixed',NaN,'ref',[],'scaled',[]);
        return
    end

    ref = decide(y / r, order);
    rref = sqrt(mean(abs(ref).^2));
    if rref <= 0
        pct = NaN; out = struct('evm',NaN,'evmGainFixed',NaN,'ref',ref,'scaled',[]);
        return
    end
    ys = y * (rref / r);

    pct = 100 * sqrt(mean(abs(ys - ref).^2)) / rref;

    out = struct('evm', pct, 'ref', ref, 'scaled', ys, 'evmGainFixed', pct);
    if p.Results.GainCorrect
        den = sum(abs(ref).^2);
        if den > 0
            g = (ref' * ys) / den;          % <ref, y> / <ref, ref>
            if g ~= 0
                out.evmGainFixed = 100 * sqrt(mean(abs(ys/g - ref).^2)) / rref;
            end
        end
    end
end

function d = decide(y, order)
% Nearest point of the unit-mean-power square QAM set.
    c = fishball.qam(order);
    [~, ix] = min(abs(y(:) - c(:).'), [], 2);
    d = c(ix);
    d = reshape(d, size(y));
end
