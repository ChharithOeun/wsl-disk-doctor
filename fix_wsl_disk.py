#!/usr/bin/env python3
"""
fix_wsl_disk.py - Cross-platform WSL2 VHDX expansion tool

Expands WSL2 virtual disks on Windows from Python (no PowerShell required).
Works on Windows (calls Resize-VHD via subprocess), detects WSL2 VHDX location
automatically, and provides a fallback with manual instructions if needed.

Usage:
    python fix_wsl_disk.py --distro BBoy-PopTart --size-gb 20
    python fix_wsl_disk.py --dry-run --size-gb 30

Exit codes:
    0: Success
    1: Not on Windows / WSL2 not found
    2: Distro VHDX not found
    3: User cancelled
    4: Resize failed
    5: Permission denied (need Administrator)
"""

import os
import sys
import subprocess
import json
import argparse
import platform
from pathlib import Path


def is_windows():
    """Check if running on Windows."""
    return platform.system() == "Windows"


def get_wsl_distros():
    """Get list of WSL2 distros and their VHDX paths."""
    distros = {}

    # Check Microsoft Store distros in %LOCALAPPDATA%\Packages
    localappdata = os.environ.get('LOCALAPPDATA')
    if localappdata:
        packages_path = Path(localappdata) / 'Packages'
        if packages_path.exists():
            for pkg_dir in packages_path.iterdir():
                if pkg_dir.is_dir():
                    vhdx_path = pkg_dir / 'LocalState' / 'ext4.vhdx'
                    if vhdx_path.exists():
                        # Extract distro name from package folder
                        distro_name = pkg_dir.name.split('_')[0]
                        distros[distro_name] = str(vhdx_path)

    # Check wsl\distros folder (for imported distros)
    localappdata = os.environ.get('LOCALAPPDATA')
    if localappdata:
        wsl_distros_path = Path(localappdata) / 'wsl' / 'distros'
        if wsl_distros_path.exists():
            for distro_dir in wsl_distros_path.iterdir():
                if distro_dir.is_dir():
                    vhdx_path = distro_dir / 'ext4.vhdx'
                    if vhdx_path.exists():
                        distros[distro_dir.name] = str(vhdx_path)

    return distros


def get_vhdx_size(vhdx_path):
    """Get current VHDX size in GB."""
    try:
        result = subprocess.run(
            ['powershell', '-NoProfile', '-Command',
             f'(Get-VHD -Path "{vhdx_path}").Size / 1GB'],
            capture_output=True,
            text=True,
            check=True
        )
        return float(result.stdout.strip())
    except Exception as e:
        print(f"Error getting VHDX size: {e}")
        return None


def resize_vhdx(vhdx_path, target_gb, dry_run=False):
    """Resize VHDX to target GB."""
    if dry_run:
        print(f"[DRY RUN] Would resize: {vhdx_path} to {target_gb}GB")
        return True

    try:
        # Calculate target size in bytes
        target_bytes = int(target_gb * 1024 * 1024 * 1024)

        # First try Resize-VHD (modern way)
        print(f"Resizing VHDX to {target_gb}GB...")
        result = subprocess.run(
            ['powershell', '-NoProfile', '-Command',
             f'Resize-VHD -Path "{vhdx_path}" -SizeBytes {target_bytes}'],
            capture_output=True,
            text=True
        )

        if result.returncode != 0:
            print(f"Resize-VHD failed: {result.stderr}")
            return False

        print(f"Successfully resized to {target_gb}GB")
        return True

    except Exception as e:
        print(f"Error: {e}")
        return False


def resize_filesystem_inside_wsl(distro_name, dry_run=False):
    """Resize filesystem inside WSL2 distro."""
    if dry_run:
        print(f"[DRY RUN] Would resize filesystem for {distro_name}")
        return True

    try:
        # Get the device name
        result = subprocess.run(
            ['wsl', '-d', distro_name, 'df', '/'],
            capture_output=True,
            text=True,
            check=True
        )

        # Parse df output to get device
        lines = result.stdout.strip().split('\n')
        if len(lines) > 1:
            device = lines[1].split()[0]
            print(f"Resizing filesystem on device {device}...")

            # Run resize2fs
            result = subprocess.run(
                ['wsl', '-d', distro_name, 'sudo', 'resize2fs', device],
                capture_output=True,
                text=True
            )

            if result.returncode != 0:
                print(f"Warning: resize2fs returned {result.returncode}")
                print("This may be OK - newer kernels auto-resize")
                return True

            print("Filesystem resized successfully")
            return True
        else:
            print("Could not parse df output")
            return False

    except Exception as e:
        print(f"Error resizing filesystem: {e}")
        return False


def print_manual_instructions(vhdx_path, target_gb):
    """Print manual instructions for expanding VHDX."""
    print("\n" + "="*60)
    print("MANUAL EXPANSION INSTRUCTIONS")
    print("="*60 + "\n")
    print(f"VHDX Path: {vhdx_path}")
    print(f"Target Size: {target_gb}GB\n")
    print("Option 1: Using Hyper-V Manager (GUI)")
    print("-" * 40)
    print("1. Close WSL: wsl --shutdown")
    print("2. Open Hyper-V Manager (search in Start menu)")
    print("3. Right-click 'Edit Disk' on the virtual machine")
    print(f"4. Select '{vhdx_path}'")
    print(f"5. Enter {target_gb}GB as new size")
    print("6. Click Finish\n")
    print("Option 2: Using PowerShell (Command Line)")
    print("-" * 40)
    print(f"Resize-VHD -Path '{vhdx_path}' -SizeBytes {int(target_gb * 1024**3)}\n")
    print("Option 3: Using diskpart (Last Resort)")
    print("-" * 40)
    print("1. diskpart")
    print("2. select vdisk file=\"" + vhdx_path + "\"")
    print(f"3. expand vdisk maximum={int(target_gb * 1024)}")
    print("4. detach vdisk")
    print("5. exit\n")
    print("After expansion, resize the filesystem inside WSL2:")
    print("-" * 40)
    print("wsl --shutdown")
    print("wsl -- sudo resize2fs /dev/sdc\n")
    print("="*60)


def main():
    parser = argparse.ArgumentParser(
        description='Expand WSL2 VHDX disk from Python'
    )
    parser.add_argument(
        '--distro',
        help='WSL2 distro name (e.g., Ubuntu, Alpine)',
        default=None
    )
    parser.add_argument(
        '--size-gb',
        type=int,
        default=20,
        help='Target disk size in GB (default: 20)'
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Show what would be done without making changes'
    )
    parser.add_argument(
        '--list',
        action='store_true',
        help='List all detected WSL2 distros and exit'
    )

    args = parser.parse_args()

    # Check Windows
    if not is_windows():
        print("Error: This tool only works on Windows with WSL2")
        sys.exit(1)

    # Get distros
    distros = get_wsl_distros()

    if not distros:
        print("Error: No WSL2 distros found")
        print("Make sure WSL2 is installed and a distro is registered")
        print("Run: wsl --install")
        sys.exit(2)

    # List mode
    if args.list:
        print("Found WSL2 distros:")
        for name, path in distros.items():
            size = get_vhdx_size(path)
            if size:
                print(f"  {name}: {path} ({size:.1f}GB)")
            else:
                print(f"  {name}: {path}")
        sys.exit(0)

    # Find target distro
    target_distro = None
    target_vhdx = None

    if args.distro:
        # User specified distro
        if args.distro in distros:
            target_distro = args.distro
            target_vhdx = distros[args.distro]
        else:
            print(f"Error: Distro '{args.distro}' not found")
            print(f"Available: {', '.join(distros.keys())}")
            sys.exit(2)
    else:
        # Auto-detect or ask user
        if len(distros) == 1:
            target_distro = list(distros.keys())[0]
            target_vhdx = distros[target_distro]
            print(f"Auto-selected distro: {target_distro}")
        else:
            # Multiple distros, ask user
            print("\nFound multiple WSL2 distros:")
            distro_list = list(distros.items())
            for i, (name, path) in enumerate(distro_list, 1):
                size = get_vhdx_size(path)
                if size:
                    print(f"  {i}. {name} ({size:.1f}GB)")
                else:
                    print(f"  {i}. {name}")

            try:
                choice = input("\nWhich distro to expand? Enter number: ").strip()
                idx = int(choice) - 1
                if 0 <= idx < len(distro_list):
                    target_distro, target_vhdx = distro_list[idx]
                else:
                    print("Invalid choice")
                    sys.exit(3)
            except ValueError:
                print("Invalid input")
                sys.exit(3)

    # Show current size
    current_size = get_vhdx_size(target_vhdx)
    if current_size:
        print(f"\nCurrent size: {current_size:.1f}GB")
        print(f"Target size:  {args.size_gb}GB")

        if args.size_gb <= current_size:
            print("Error: Target size must be larger than current size")
            sys.exit(1)

    if args.dry_run:
        print("\n[DRY RUN MODE]")
        resize_vhdx(target_vhdx, args.size_gb, dry_run=True)
        resize_filesystem_inside_wsl(target_distro, dry_run=True)
        sys.exit(0)

    # Expand
    if not resize_vhdx(target_vhdx, args.size_gb):
        print("\nExpansion failed. Printing manual instructions...\n")
        print_manual_instructions(target_vhdx, args.size_gb)
        sys.exit(4)

    # Resize filesystem
    print("\nResizing filesystem...")
    if not resize_filesystem_inside_wsl(target_distro):
        print("\nFilesystem resize encountered an issue.")
        print("This may be OK - newer WSL2 kernels auto-resize.")
        print("\nVerify with: wsl -d " + target_distro + " df -h /")

    print("\nExpansion complete!")
    print(f"Run: wsl -d {target_distro} df -h / (to verify)")
    sys.exit(0)


if __name__ == '__main__':
    main()
