# Computes width (dz) and density (rho) per level
generate_isa_profile <- function(hysplit_heights) {
  T0 <- 288.15 # Temperature at sea level (K)
  P0 <- 101325 # Pressure at sea level (Pa)
  L <- 0.0065 # Lapse rate (K/m)
  Rd <- 287.05 # Gases constant for dry air (J/(kg K))
  g <- 9.80665 # gravity (m/s^2)

  sorted_heights <- sort(unique(hysplit_heights))

  tibble(height = sorted_heights) %>%
    mutate(
      dz = height - lag(height, default = 0),
      z_mid = height - (dz / 2),
      # Isa Equations
      T_z = T0 - (L * z_mid),
      P_z = P0 * (1 - (L * z_mid) / T0)^(g / (Rd * L)),
      rho = P_z / (Rd * T_z) #kg/m^3
    ) %>%
    select(height, dz, rho)
}
