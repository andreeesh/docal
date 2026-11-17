#!/usr/bin/env python3
"""Opt-in, reversible Mailpit SMTP routing for existing local WordPress sites."""

import argparse
import os
from pathlib import Path
import sys

PLUGIN_NAME = "docal-mailpit-capture.php"
PLUGIN_SOURCE = """<?php
/**
 * Plugin Name: Docal Mailpit Local Capture
 * Description: Route standard WordPress wp_mail() through the local Docker Mailpit sink.
 * Version: 1.0.0
 */
defined('ABSPATH') || exit;

// Opt-in development-only interception. Executed after normal SMTP plugin
// handlers so ordinary PHPMailer traffic uses the local sink.
add_action('phpmailer_init', static function ($mailer) {
    $mailer->isSMTP();
    $mailer->Host = 'docal-mailpit';
    $mailer->Port = 1025;
    $mailer->SMTPAuth = false;
    $mailer->SMTPSecure = '';
    $mailer->SMTPAutoTLS = false;
}, PHP_INT_MAX);
"""


def site_plugin_path(site_dir):
    if site_dir.is_symlink() or not site_dir.is_dir():
        raise ValueError("Docal site directory is missing or symlinked")
    if not (site_dir / "docker-compose.yml").is_file() or not (site_dir / ".env").is_file():
        raise ValueError("Not a managed Docal site")
    if (site_dir / ".docal-import-pending").exists():
        raise ValueError("Cannot modify an incomplete WordPress import")
    wp = site_dir / "wordpress"
    content = wp / "wp-content"
    mu = content / "mu-plugins"
    for entry in (wp, content, mu):
        if entry.is_symlink():
            raise ValueError("Refusing symlinked WordPress plugin path")
    if not wp.is_dir() or not content.is_dir() or not (wp / "wp-config.php").is_file():
        raise ValueError("Local WordPress content or configuration is missing")
    if mu.exists() and not mu.is_dir():
        raise ValueError("WordPress mu-plugins path is not a directory")
    return mu / PLUGIN_NAME


def enable(site_dir):
    target = site_plugin_path(site_dir)
    if target.is_symlink():
        raise ValueError("Refusing symlinked Mailpit plugin file")
    if target.exists():
        if not target.is_file() or target.read_text(encoding="utf-8") != PLUGIN_SOURCE:
            raise ValueError("Existing Mailpit plugin differs; refusing overwrite")
        print("[ok] Docal Mailpit site integration is already enabled")
        return
    target.parent.mkdir(mode=0o755, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(target, flags, 0o644)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write(PLUGIN_SOURCE)
    except BaseException:
        target.unlink(missing_ok=True)
        raise
    print("[ok] WordPress wp_mail() will use local docal-mailpit:1025 in normal mode")


def disable(site_dir):
    target = site_plugin_path(site_dir)
    if target.is_symlink():
        raise ValueError("Refusing symlinked Mailpit plugin file")
    if not target.exists():
        print("[ok] Docal Mailpit site integration was already disabled")
        return
    if not target.is_file() or target.read_text(encoding="utf-8") != PLUGIN_SOURCE:
        raise ValueError("Existing Mailpit plugin differs; refusing to delete modified file")
    target.unlink()
    print("[ok] Docal Mailpit site integration disabled; other plugins untouched")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("enable", "disable"))
    parser.add_argument("--site-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        (enable if args.action == "enable" else disable)(args.site_dir.absolute())
    except (OSError, UnicodeError, ValueError) as error:
        print("[error] Mailpit site integration: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
