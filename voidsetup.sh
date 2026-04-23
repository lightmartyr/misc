#!/bin/bash

set -e

echo "--- Hardened Noctalia + Turnstile Setup ---"

# 1. Repository Setup
echo "Adding Noctalia repository..."
sudo mkdir -p /etc/xbps.d
echo "repository=https://universalrepo.r1xelelo.workers.dev/void" \
  | sudo tee /etc/xbps.d/10-noctalia.conf
sudo xbps-install -S

# 2. Package Installation
# Removed NVIDIA drivers as requested. Includes XWayland for compatibility.
echo "Installing packages..."
sudo xbps-install -y \
    mangowc noctalia-shell noctalia-qs tuigreet greetd \
    turnstile turnstile-runit seatd pipewire wireplumber \
    pipewire-pulse dbus xorg-server-xwayland

# 3. System Services & Permissions
sudo ln -sf /etc/sv/seatd /var/service/
sudo ln -sf /etc/sv/turnstiled /var/service/

for user in "$USER" "greeter"; do
    sudo usermod -aG _seatd,video,audio,bluetooth "$user"
done

# 4. Environment Variables (Optimized for NVIDIA 595+)
mkdir -p "$HOME/.config"
cat <<EOF > "$HOME/.config/environment"
export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM="wayland;xcb"
export SDL_VIDEODRIVER=wayland
export _JAVA_AWT_WM_NONREPARENTING=1
export XDG_CURRENT_DESKTOP=mangowc
export XDG_SESSION_TYPE=wayland
export LIBVA_DRIVER_NAME=nvidia
export NVD_BACKEND=direct
EOF

# 5. User Services (Turnstile-Runit)
# Path verified: ~/.config/service/
SERVICE_DIR="$HOME/.config/service"
mkdir -p "$SERVICE_DIR/dbus" "$SERVICE_DIR/turnstile-ready"

# D-Bus
ln -sf /usr/share/examples/turnstile/dbus.run "$SERVICE_DIR/dbus/run"
echo 'core_services="dbus"' > "$SERVICE_DIR/turnstile-ready/conf"

# The Audio Trio
for svc in pipewire wireplumber pipewire-pulse; do
    mkdir -p "$SERVICE_DIR/$svc"
    echo -e "#!/bin/sh\n[ -f \"\$HOME/.config/environment\" ] && . \"\$HOME/.config/environment\"\nexec chpst -e \"\$TURNSTILE_ENV_DIR\" $svc" > "$SERVICE_DIR/$svc/run"
    chmod +x "$SERVICE_DIR/$svc/run"
done

# The Supervised Shell
mkdir -p "$SERVICE_DIR/noctalia-shell"
cat <<EOF > "$SERVICE_DIR/noctalia-shell/run"
#!/bin/sh
sleep 1
[ -f "\$HOME/.config/environment" ] && . "\$HOME/.config/environment"
exec chpst -e "\$TURNSTILE_ENV_DIR" qs -c noctalia-shell
EOF
chmod +x "$SERVICE_DIR/noctalia-shell/run"

# 6. Greetd Config
sudo mkdir -p /etc/greetd
cat <<EOF | sudo tee /etc/greetd/config.toml
[default_session]
command = "tuigreet --cmd 'turnstile-session mangowc' --time --remember --asterisks"
user = "greeter"
EOF

# 7. MangoWC Config Initialization
# Path verified: ~/.config/mango/config.conf
echo "Configuring MangoWC..."
mkdir -p "$HOME/.config/mango"
if [ -f /etc/mango/config.conf ]; then
    cp /etc/mango/config.conf "$HOME/.config/mango/config.conf"
fi
# Prepend environment sourcing
echo ". \$HOME/.config/environment" | cat - "$HOME/.config/mango/config.conf" > temp && mv temp "$HOME/.config/mango/config.conf"

echo "--- Setup Complete ---"
echo "Don't forget to run 'sudo dracut -f' after you finish your NVIDIA driver install."