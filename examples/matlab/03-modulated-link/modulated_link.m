function [evmPct, out] = modulated_link(varargin)
%MODULATED_LINK  A QPSK/QAM link through your own loopback, measured in EVM.
%
%   >> modulated_link('PadDb', 20)                    % TX1 -> pad -> RX1
%   >> modulated_link('PadDb', 20, 'Order', 16)       % 16-QAM
%   >> modulated_link('PadDb', 20, 'TxChannel', 2, 'RxChannel', 2)
%   >> modulated_link('Source', 'loopback')           % no cable, no RF at all
%
%   !! THIS TRANSMITS !!
%
% PadDb is required. This board reaches about +19 dBm and its own receive port
% is rated +2.5 dBm, so a cable from TX to RX with no attenuator in it destroys
% the receiver. Fit at least 20 dB. If you have no attenuator, use
% 'Source','loopback', which uses the AD9361's INTERNAL digital loopback and
% radiates nothing at all.
%
% WHAT IT MEASURES. EVM - how far each received symbol lands from where it
% should, as a percentage. It is the number every impairment eventually shows
% up in, and the one worth watching while you change something. Through 20 dB
% on this board you should see a few percent; if you see 30% you are looking at
% a receiver problem, not a link problem.
%
% THE CHAIN
%   random symbols -> RRC pulse shaping -> cyclic transmit
%   capture -> matched filter -> symbol timing -> carrier recovery -> EVM
%
% Timing and carrier recovery are Communications Toolbox System objects rather
% than hand-rolled, because that is what you would actually use and because the
% point of the example is the measurement, not the loops.

    p = inputParser;
    p.addParameter('PadDb', [], @(v) isnumeric(v) && isscalar(v));
    p.addParameter('Order', 4, @(v) any(v == [4 16 64]));
    p.addParameter('TxChannel', 1, @(v) any(v == [1 2]));
    p.addParameter('RxChannel', 1, @(v) any(v == [1 2]));
    p.addParameter('CenterFrequency', 900e6, @isnumeric);
    p.addParameter('SampleRate', 3e6, @isnumeric);
    p.addParameter('SamplesPerSymbol', 4, @isnumeric);
    p.addParameter('TxGain', -30, @isnumeric);
    p.addParameter('RxGain', 20, @isnumeric);
    p.addParameter('NumSymbols', 4096, @isnumeric);
    p.addParameter('Source', 'rf', @(s) ischar(s) || isstring(s));
    p.addParameter('Plot', true, @islogical);
    p.parse(varargin{:});
    r = p.Results;
    sps = r.SamplesPerSymbol;
    internal = strcmpi(char(r.Source), 'loopback');

    if internal && isempty(r.PadDb), r.PadDb = 0; end

    %% 1 - the waveform
    c = fishball.qam(r.Order);
    bits = randi(numel(c), r.NumSymbols, 1);
    sym = c(bits);
    rrcTx = comm.RaisedCosineTransmitFilter( ...
        'RolloffFactor', 0.35, 'FilterSpanInSymbols', 10, ...
        'OutputSamplesPerSymbol', sps);
    w = rrcTx(sym);
    w = w / max(abs(w)) * 0.7;        % headroom: the DAC clips hard at +/-1

    fprintf('\n== transmitting ==\n');
    fprintf('  %d-QAM, %d symbols, %.0f ksym/s (%.2f MSPS / %d sps)\n', ...
            r.Order, r.NumSymbols, r.SampleRate/sps/1e3, r.SampleRate/1e6, sps);

    %% 2 - put it on the air (or not)
    cleanupLoop = [];
    if internal
        fprintf('  INTERNAL digital loopback - nothing is radiated.\n');
        setLoopback(1);
        cleanupLoop = onCleanup(@() setLoopback(0));
    end
    tx = fishball.safeTransmit(w, 'PadDb', r.PadDb, 'Gain', r.TxGain, ...
                               'TxChannel', r.TxChannel, ...
                               'CenterFrequency', r.CenterFrequency, ...
                               'BasebandSampleRate', r.SampleRate);
    cleanupTx = onCleanup(@() release(tx));
    pause(0.5);

    %% 3 - receive it
    n = r.NumSymbols * sps * 2;
    if r.RxChannel == 1
        rx = fishball.connect('CenterFrequency', r.CenterFrequency, ...
                              'BasebandSampleRate', r.SampleRate, ...
                              'SamplesPerFrame', n, 'Gain', r.RxGain);
        cleanupRx = onCleanup(@() release(rx)); %#ok<NASGU>
        rx(); y = double(rx());
    else
        both = fishball.capture2('CenterFrequency', r.CenterFrequency, ...
                                 'SampleRate', r.SampleRate, ...
                                 'Seconds', n / r.SampleRate, 'Gain', r.RxGain);
        y = both(:, 2);
    end
    fprintf('\n== received on RX%d ==\n', r.RxChannel);
    % The +/-2047 limit is PER COMPONENT. Testing abs(y) instead is wrong and
    % wrong in the flattering direction: |I + jQ| reaches 2895 with neither I
    % nor Q anywhere near clipping, so a magnitude check cries wolf, and it can
    % equally miss a real clip on one axis. Check I and Q.
    pk = max(max(abs(real(y))), max(abs(imag(y))));
    fprintf('  %d samples, rms %.1f counts, peak |I| or |Q| = %.0f of 2047\n', ...
            numel(y), rms(y), pk);
    if pk > 2000
        warning('fishball:link:clipping', ...
            ['The receiver is at full scale (%d of 2047 on I or Q). Lower ' ...
             'RxGain - a clipped\nconstellation measures your ADC, not your ' ...
             'link.'], round(pk));
    elseif pk < 50
        warning('fishball:link:quiet', ...
            ['Only %d counts of 2047. Raise RxGain or TxGain - EVM on noise ' ...
             'is noise.'], round(pk));
    end

    %% 4 - recover it
    y = y / rms(y);
    rrcRx = comm.RaisedCosineReceiveFilter( ...
        'RolloffFactor', 0.35, 'FilterSpanInSymbols', 10, ...
        'InputSamplesPerSymbol', sps, 'DecimationFactor', 1);
    yf = rrcRx(y);

    sync = comm.SymbolSynchronizer('SamplesPerSymbol', sps, ...
        'TimingErrorDetector', 'Gardner (non-data-aided)', ...
        'NormalizedLoopBandwidth', 0.005);
    ys = sync(yf);

    carr = comm.CarrierSynchronizer('Modulation', 'QAM', ...
        'ModulationPhaseOffset', 'Auto', 'SamplesPerSymbol', 1, ...
        'NormalizedLoopBandwidth', 0.005);
    yc = carr(ys);

    % Discard the loops' settling time. Measuring through a transient is the
    % most common way to publish an EVM worse than the hardware's.
    keep = round(numel(yc) * 0.4);
    yc = yc(end-keep+1:end);

    [evmPct, out] = fishball.evm(yc, r.Order);
    out.symbols = yc;

    fprintf('\n== measured ==\n');
    fprintf('  symbols used          %d (last 40%%, after the loops settle)\n', keep);
    fprintf('  EVM                   %.2f %%\n', evmPct);
    fprintf('  EVM after one-tap gain/phase fix %.2f %%\n', out.evmGainFixed);
    fprintf('  implied SNR           %.1f dB\n', -20*log10(evmPct/100));

    if r.Plot, plotIt(out.scaled, r, evmPct); end
    if nargout == 0, clear evmPct out, end
end

function setLoopback(v)
% The AD9361's internal digital loopback, via the tool this repo already has
% for it. Nothing is radiated: transmit samples are routed into the receive
% path INSIDE the chip, never reaching a mixer, the amplifier or a port.
%
% Caveats worth knowing, from tools/examples_loopback.py: there is no
% frequency translation, so TX and RX LO offsets do not cancel; the analogue
% attenuator does not apply, so TxGain does nothing here; and a board left in
% loopback receives nothing from its antennas and looks broken. This function
% always turns it back off through an onCleanup.
    root = fishball.repoRoot();
    names = {'off', 'on'};
    cmd = sprintf('python3 %s %s >/dev/null 2>&1', ...
                  fullfile(root, 'tools', 'examples_loopback.py'), names{v+1});
    if system(cmd) ~= 0
        warning('fishball:link:loopback', ...
                'could not set the internal loopback %s', names{v+1});
    end
end

function plotIt(yc, r, evmPct)
% yc must be the symbols ON THE REFERENCE'S SCALE - fishball.evm returns them
% as out.scaled. Plotting the raw recovered symbols against the unit-mean-power
% constellation puts the cloud and the red reference markers on different
% scales: measured 16-QAM landed at +/-2.11 against a reference at +/-0.95, so
% the markers sat in the middle of the picture touching nothing. The EVM number
% was right the whole time, which is what made it a plotting bug rather than a
% measurement one.
    fig = findobj('Type','figure','Tag','fishball_link');
    if isempty(fig), fig = figure('Tag','fishball_link','Color','w');
    else, fig = fig(1); clf(fig); end
    set(fig,'Name','modulated link');
    ax = axes(fig); %#ok<LAXES>
    plot(ax, real(yc), imag(yc), '.', 'MarkerSize', 4); hold(ax,'on');
    c = fishball.qam(r.Order);
    plot(ax, real(c), imag(c), 'r+', 'MarkerSize', 10, 'LineWidth', 1.5);
    grid(ax,'on'); axis(ax,'equal');
    % Symmetric limits around the constellation, so the grid reads as a grid
    % rather than whatever the data's own extremes happened to be.
    lim = max(max(abs(c))*1.6, max(abs([real(yc); imag(yc)])) * 1.05);
    xlim(ax, [-lim lim]); ylim(ax, [-lim lim]);
    xlabel(ax,'I'); ylabel(ax,'Q');
    title(ax, sprintf('%d-QAM  TX%d -> RX%d  EVM %.2f %%', ...
                      r.Order, r.TxChannel, r.RxChannel, evmPct));
end
