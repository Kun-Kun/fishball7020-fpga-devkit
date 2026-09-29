function firmwareNote()
%FIRMWARENOTE  Say the safety-relevant half of MathWorks' warning, once.
%
% The support package warns that it was tested against firmware v0.39 and
% offers to "switch the firmware version" through the Hardware Setup App. The
% warning is fair; the offer is not. That image is for an ADALM-Pluto, which is
% a Zynq-7010 with an AD9363. This board is a Zynq-7020 with an AD9361 - a
% different FPGA and a different transceiver, and on the common variant a power
% amplifier the Pluto does not have.
%
% Printed once per MATLAB session, because a warning nobody reads twice is a
% warning nobody reads.
    persistent shown
    if ~isempty(shown), return, end
    shown = true;
    fprintf(['  [fishball] MATLAB expects Pluto firmware v0.39 and will say ' ...
             'so. That is fine.\n' ...
             '             Do NOT accept its offer to update the firmware - ' ...
             'that image is for a\n' ...
             '             Zynq-7010 ADALM-Pluto, not this Zynq-7020 board. ' ...
             'See docs/matlab.md.\n']);
end
