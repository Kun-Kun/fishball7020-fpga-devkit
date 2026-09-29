function app = spectrum_app(varargin)
%SPECTRUM_APP  A live spectrum window: tune, span, gain, max-hold, either receiver.
%
%   >> spectrum_app                                  % RX1, 900 MHz
%   >> spectrum_app('RxChannel', 2, 'CenterFrequency', 90.4e6)
%   >> app = spectrum_app; ... ; close(app.Fig)
%
% Receive only. Nothing here transmits.
%
% WHY THIS IS A FUNCTION AND NOT A .mlapp. App Designer stores an app as a
% binary file. It works, and a binary in a repository cannot be reviewed, cannot
% be diffed, and cannot be merged - and this repository already takes the view
% that a generated artefact ships with the thing that generates it. A uifigure
% built in code is a few dozen lines you can read and change in an editor.
%
% WHAT IT IS FOR. Seeing. Tuning by typing a number and watching the band move
% is how you find out what is actually around you, and max-hold is how you
% catch something that is only there sometimes - a remote control, a doorbell,
% a car key. The numbers under the plot are the same ones fishball.spectrum
% computes for the other examples, so what you see here and what you measure
% there agree.
%
% THE FLOOR IS THE MEDIAN BIN, not the minimum. A minimum is one unlucky bin
% and jumps around; the median is the level most of the band is sitting at.

    p = inputParser;
    p.addParameter('CenterFrequency', 900e6, @isnumeric);
    p.addParameter('SampleRate', 3e6, @isnumeric);
    p.addParameter('Gain', 45, @isnumeric);
    p.addParameter('RxChannel', 1, @(v) any(v == [1 2]));
    p.addParameter('Nfft', 4096, @isnumeric);
    % Frames exists so this can be TESTED. A window that runs until closed
    % cannot be checked by a script, and an example nobody can check is an
    % example that quietly rots. Leave it Inf to use the thing.
    p.addParameter('Frames', Inf, @isnumeric);
    p.addParameter('Visible', true, @islogical);
    p.parse(varargin{:});
    st = p.Results;
    st.hold = false;
    st.peak = [];
    st.rx = [];
    st.running = true;

    % ---- the window -----------------------------------------------------
    f = uifigure('Name','Fishball7020 spectrum','Position',[100 100 980 620], ...
                 'Visible', st.Visible);
    g = uigridlayout(f, [2 1]);
    g.RowHeight = {'1x', 132};

    ax = uiaxes(g);
    ax.Layout.Row = 1;
    xlabel(ax,'MHz'); ylabel(ax,'dBFS'); grid(ax,'on');
    ln  = plot(ax, nan, nan, 'LineWidth', 1);            hold(ax,'on');
    lnH = plot(ax, nan, nan, 'LineWidth', 1, 'Color', [0.85 0.33 0.10]);
    legend(ax, {'live','max hold'}, 'Location','northeast');

    c = uigridlayout(g, [2 7]);
    c.Layout.Row = 2;
    c.RowHeight = {22, 34};
    c.ColumnWidth = {110,110,90,90,110,110,'1x'};

    lbl(c,1,'Centre, MHz');  lbl(c,2,'Span, MSPS'); lbl(c,3,'Gain, dB');
    lbl(c,4,'Receiver');     lbl(c,5,'');           lbl(c,6,'');
    lbl(c,7,'');

    eF = num(c, 1, st.CenterFrequency/1e6);
    eS = num(c, 2, st.SampleRate/1e6);
    eG = num(c, 3, st.Gain);
    dC = uidropdown(c, 'Items', {'RX1','RX2'}, 'Value', sprintf('RX%d', st.RxChannel));
    dC.Layout.Row = 2; dC.Layout.Column = 4;
    bH = uibutton(c,'state','Text','max hold');
    bH.Layout.Row = 2; bH.Layout.Column = 5;
    bR = uibutton(c,'push','Text','reset hold');
    bR.Layout.Row = 2; bR.Layout.Column = 6;
    info = uilabel(c,'Text','starting...','FontName','monospaced');
    info.Layout.Row = 2; info.Layout.Column = 7;

    % ---- wiring ---------------------------------------------------------
    bH.ValueChangedFcn = @(s,~) setfield_('hold', s.Value);
    bR.ButtonPushedFcn = @(~,~) setfield_('peak', []);
    eF.ValueChangedFcn = @(s,~) retune('CenterFrequency', s.Value*1e6);
    eS.ValueChangedFcn = @(s,~) retune('SampleRate',      s.Value*1e6);
    eG.ValueChangedFcn = @(s,~) retune('Gain',            s.Value);
    dC.ValueChangedFcn = @(s,~) retune('RxChannel', str2double(s.Value(3)));
    f.CloseRequestFcn  = @(~,~) shutdown();

    app = struct('Fig', f, 'Axes', ax);
    if nargout == 0, clear app, end
    loop();

    % ---- the parts that do something ------------------------------------
    function loop()
        nf = 0;
        while st.running && isvalid(f) && nf < st.Frames
            x = grabOnce();
            if isempty(x), pause(0.05); continue, end
            [db, fr] = fishball.spectrum(x, st.SampleRate, 'FullScale', 2047);
            mhz = (st.CenterFrequency + fr)/1e6;

            if st.hold
                if isempty(st.peak) || numel(st.peak) ~= numel(db)
                    st.peak = db;
                else
                    st.peak = max(st.peak, db);
                end
            end

            set(ln,  'XData', mhz, 'YData', db);
            if st.hold && ~isempty(st.peak)
                set(lnH, 'XData', mhz, 'YData', st.peak);
            else
                set(lnH, 'XData', nan, 'YData', nan);
            end

            fl = median(db); [pk, ix] = max(db);
            % A clipped converter makes a spectrum that looks like a big signal
            % and is mostly the clipping. Say so rather than drawing it plainly.
            over = max(max(abs(real(x))), max(abs(imag(x)))) >= 2047;
            ylim(ax, [fl-12, max(pk+8, fl+30)]);
            xlim(ax, [mhz(1) mhz(end)]);
            info.Text = sprintf(['peak %+7.1f dBFS @ %9.4f MHz   floor %+7.1f' ...
                                 '   %+5.1f dB up%s'], ...
                                pk, mhz(ix), fl, pk-fl, ...
                                stringIf(over, '   *** OVERLOAD: lower the gain ***'));
            if over, info.FontColor = [0.8 0 0]; else, info.FontColor = [0 0 0]; end
            drawnow limitrate
            nf = nf + 1;
        end
    end

    function x = grabOnce()
        x = [];
        try
            if st.RxChannel == 1
                if isempty(st.rx)
                    setBandwidth();
                    st.rx = fishball.connect('CenterFrequency', st.CenterFrequency, ...
                                             'BasebandSampleRate', st.SampleRate, ...
                                             'SamplesPerFrame', st.Nfft, ...
                                             'Gain', st.Gain);
                end
                x = double(st.rx());
            else
                b = fishball.capture2('CenterFrequency', st.CenterFrequency, ...
                                      'SampleRate', st.SampleRate, ...
                                      'Seconds', st.Nfft/st.SampleRate, ...
                                      'Gain', st.Gain, 'Bandwidth', st.SampleRate);
                x = b(:,2);
            end
        catch e
            info.Text = ['! ' strtrim(e.message)];
            pause(0.4);
        end
        if numel(x) > st.Nfft, x = x(1:st.Nfft); end
    end

    function retune(field, value)
        st.(field) = value;
        st.peak = [];
        % A System object will not take a new setting while it is running, and
        % changing one silently does nothing - so it is thrown away and rebuilt.
        % Same trap pyadi-iio has, where the fix is rx_destroy_buffer().
        releaseRx();
    end

    function setfield_(field, value)
        st.(field) = value;
        if strcmp(field,'hold') && ~value, st.peak = []; end
    end

    function setBandwidth()
        % The analogue channel filter should match what you are looking at. Left
        % at whatever the last program set, the picture you get is the FILTER'S
        % shape rather than the band's - a narrow peak with wide skirts that
        % looks like a signal and is not.
        u = fishball.uri();
        for ch = {'voltage0','voltage1'}
            system(sprintf(['iio_attr -u %s -i -c ad9361-phy %s rf_bandwidth ' ...
                            '%d >/dev/null 2>&1'], u, ch{1}, round(st.SampleRate)));
        end
    end

    function s_ = stringIf(c, t), if c, s_ = t; else, s_ = ''; end, end

    function releaseRx()
        if ~isempty(st.rx), try, release(st.rx); catch, end, st.rx = []; end
    end

    function shutdown()
        st.running = false;
        releaseRx();
        delete(f);
    end

    function e = num(parent, col, v)
        e = uieditfield(parent, 'numeric', 'Value', v);
        e.Layout.Row = 2; e.Layout.Column = col;
    end
    function l = lbl(parent, col, text)
        l = uilabel(parent, 'Text', text);
        l.Layout.Row = 1; l.Layout.Column = col;
    end
end
