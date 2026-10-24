source ../../scripts/adi_env.tcl
source $ad_hdl_dir/library/scripts/adi_ip_xilinx.tcl

adi_ip_create tx_fir_interpolator

set fir [create_ip -name fir_compiler -vendor xilinx.com \
  -library ip -version 7.2 -module_name fir_interpolator]
set_property -dict [list \
  CONFIG.Clock_Frequency {61.44} \
  CONFIG.CoefficientSource {COE_File} \
  CONFIG.Coefficient_File [file normalize [file join [pwd] coefile_int.coe]] \
  CONFIG.Coefficient_Fractional_Bits {0} \
  CONFIG.Data_Fractional_Bits {15} \
  CONFIG.Coefficient_Sets {1} \
  CONFIG.Coefficient_Sign {Signed} \
  CONFIG.Coefficient_Structure {Inferred} \
  CONFIG.Coefficient_Width {16} \
  CONFIG.ColumnConfig {5} \
  CONFIG.Decimation_Rate {1} \
  CONFIG.Filter_Architecture {Systolic_Multiply_Accumulate} \
  CONFIG.Filter_Type {Interpolation} \
  CONFIG.Interpolation_Rate {8} \
  CONFIG.M_DATA_HAS_TREADY {true} \
  CONFIG.Number_Channels {1} \
  CONFIG.Number_Paths {1} \
  CONFIG.Output_Rounding_Mode {Symmetric_Rounding_to_Zero} \
  CONFIG.Output_Width {16} \
  CONFIG.Quantization {Integer_Coefficients} \
  CONFIG.RateSpecification {Frequency_Specification} \
  CONFIG.Sample_Frequency {7.68} \
  CONFIG.Zero_Pack_Factor {1} \
] [get_ips fir_interpolator]

generate_target {all} [get_files tx_fir_interpolator.srcs/sources_1/ip/fir_interpolator/fir_interpolator.xci]

adi_ip_files tx_fir_interpolator [list \
  "tx_fir_interpolator.v" \
  "sync_bits.v" \
]
adi_ip_properties_lite tx_fir_interpolator

set cc [ipx::current_core]
foreach {bus mode} {s_axis slave m_axis master} {
  adi_add_bus $bus $mode \
    "xilinx.com:interface:axis_rtl:1.0" \
    "xilinx.com:interface:axis:1.0" \
    [list \
      [list "${bus}_tdata" "TDATA"] \
      [list "${bus}_tvalid" "TVALID"] \
      [list "${bus}_tready" "TREADY"]]
}
adi_add_bus_clock "aclk" "s_axis:m_axis" "reset"

ipx::save_core [ipx::current_core]
