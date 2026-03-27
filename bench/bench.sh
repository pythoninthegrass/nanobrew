#!/bin/bash
set -e

PACKAGES="curl wget tree jq htop tmux"

echo "============================================"
echo "  nanobrew vs apt-get benchmark"
echo "  Packages: $PACKAGES"
echo "  $(grep PRETTY_NAME /etc/os-release)"
echo "  $(uname -m)"
echo "============================================"
echo ""

# --- Benchmark apt-get (cold) ---
echo ">>> [apt-get] Cold install..."
apt-get clean >/dev/null 2>&1
time_apt_start=$(date +%s%N)
apt-get install -y $PACKAGES >/dev/null 2>&1
time_apt_end=$(date +%s%N)
apt_ms=$(( (time_apt_end - time_apt_start) / 1000000 ))
echo ">>> [apt-get] Cold: ${apt_ms}ms"

# --- Benchmark apt-get (warm — reinstall) ---
apt-get remove -y $PACKAGES >/dev/null 2>&1
time_apt2_start=$(date +%s%N)
apt-get install -y $PACKAGES >/dev/null 2>&1
time_apt2_end=$(date +%s%N)
apt2_ms=$(( (time_apt2_end - time_apt2_start) / 1000000 ))
echo ">>> [apt-get] Warm: ${apt2_ms}ms"
apt-get remove -y $PACKAGES >/dev/null 2>&1
apt-get autoremove -y >/dev/null 2>&1
echo ""

# --- Benchmark nanobrew (cold) ---
echo ">>> [nanobrew] Cold install..."
time_nb_start=$(date +%s%N)
nb install --deb $PACKAGES 2>&1 || true
time_nb_end=$(date +%s%N)
nb_cold_ms=$(( (time_nb_end - time_nb_start) / 1000000 ))
echo ">>> [nanobrew] Cold: ${nb_cold_ms}ms"

# --- Benchmark nanobrew (warm — .debs cached) ---
echo ">>> [nanobrew] Warm install (cached .debs)..."
nb remove --deb $PACKAGES >/dev/null 2>&1 || true
time_nb2_start=$(date +%s%N)
nb install --deb --skip-postinst $PACKAGES 2>&1 || true
time_nb2_end=$(date +%s%N)
nb_warm_ms=$(( (time_nb2_end - time_nb2_start) / 1000000 ))
echo ">>> [nanobrew] Warm (no postinst): ${nb_warm_ms}ms"
echo ""
echo "============================================"
echo "  RESULTS"
echo "============================================"
echo "  apt-get cold:    ${apt_ms}ms"
echo "  apt-get warm:    ${apt2_ms}ms"
echo "  nanobrew cold:   ${nb_cold_ms}ms"
echo "  nanobrew warm:   ${nb_warm_ms}ms"
echo "============================================"
