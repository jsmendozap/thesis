pacman::p_load("proporz", "tidyverse")

# Van der Corput sequence
van_der_corput <- function(n) {
  vapply(
    seq_len(n) - 1,
    function(i) {
      bits <- as.integer(intToBits(i))
      sum(bits / 2^seq_along(bits))
    },
    numeric(1)
  )
}

height_levels <- function(profile, n) {
  base <- profile %>%
    filter(level %in% 350:1000) %>%
    summarise(flux = mean(flux), .by = level) %>%
    mutate(level = as.integer(as.character(level))) %>%
    arrange(level)

  n_real_levels <- nrow(base)

  # divisor_floor = D'Hondt. Splits n spots into the "votes" (flux).
  n_remaining <- n - n_real_levels

  particles <- 1L + divisor_floor(base$flux, n_remaining)

  base %>%
    mutate(particles_level = particles) %>%
    arrange(level) %>%
    mutate(next_level = lead(level, default = max(level) + 25)) %>%
    group_by(level) %>%
    reframe(
      levels = level + van_der_corput(particles_level) * (next_level - level)
    ) %>%
    pull(levels) %>%
    {
      8000 * log(1014 / .)
    } %>%
    round(digits = -1)
}
