# Pre-requisites  
1. Raspberry Pi 4  
2. Behringer U-PHORIA UMC22  
3. DSI touchscreen  
4. Raspberry Pi OS Bookworm 64 bit (full)    

# Installation  
#### On a fresh installation of Raspberry Pi Os  
```
cd ~
wget https://raw.githubusercontent.com/<your-user>/<your-repo>/main/drumbrain-setup.sh
chmod +x drumbrain-setup.sh
./drumbrain-setup.sh
sudo reboot
```

#### After reboot:
```
systemctl status drumbrain-jackd
systemctl status drumbrain-drumgizmo
systemctl status jack-plumbing
jack_lsp -c
```    

##### You should see:  
```
DrumGizmo:drumgizmo_midiin
DrumGizmo:0-Left
    system:playback_1
DrumGizmo:1-Right
    system:playback_2
```


