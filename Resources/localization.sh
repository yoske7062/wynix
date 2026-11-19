#!/bin/bash

macsteam_ui_language() {
  printf 'en\n'
}

MACSTEAM_RESOLVED_LANGUAGE="$(macsteam_ui_language)"

ui_text() {
  local key="$1"
  shift
  local format

  case "$MACSTEAM_RESOLVED_LANGUAGE:$key" in
    en:steam_language_environment_missing) format='The Wine environment required to configure the Steam language was not found' ;;
    en:steam_language_config_failed) format='Could not configure the initial Steam language' ;;
    en:unsafe_lock_path) format='The setup lock path is unsafe' ;;
    en:installation_already_running) format='Setup is already running' ;;
    en:stale_lock_cleanup_failed) format='Could not remove the stale setup lock' ;;
    en:installed_steam_not_found) format='The installed Windows Steam app was not found' ;;
    en:steam_window_reopen_failed) format='Could not reopen the Steam window' ;;
    en:steam_window_foregrounded) format='Brought the Windows Steam window to the front' ;;
    en:steam_stalled_restarting) format='Cleaning up a stalled Steam launch and trying again' ;;
    en:steam_stalled_cleanup_failed) format='Could not clean up the stalled Windows Steam launch' ;;
    en:steam_starting) format='Starting Windows Steam' ;;
    en:steam_start_requested) format='Requested Windows Steam to start' ;;
    en:steam_stopping) format='Stopping Windows Steam and running Windows games' ;;
    en:steam_launcher_not_found) format='The Windows Steam launcher was not found' ;;
    en:steam_stop_failed) format='Could not completely stop Windows Steam' ;;
    en:steam_stopped) format='Windows Steam was completely stopped' ;;
    en:games_drive_missing) format='Your games drive is not connected. Plug it in and try again' ;;
    en:no_installed_games) format='No installed Windows Steam games were found' ;;
    en:invalid_game_id) format='The Steam game ID is invalid' ;;
    en:game_info_not_found) format='The installed game information was not found' ;;
    en:game_info_read_failed) format='Could not read the game information' ;;
    en:game_id_mismatch) format='The game ID does not match the installed game information' ;;
    en:game_name_read_failed) format='Could not read the game name' ;;
    en:game_install_read_failed) format='Could not read the game installation information' ;;
    en:unsafe_shortcut_path) format='The game shortcut path is unsafe' ;;
    en:shortcut_conflict) format='An existing file has the same name and was not overwritten: %s' ;;
    en:shortcut_created) format='Created a shortcut for %s' ;;
    en:repairing_login) format='Resetting temporary data for the Steam login screen' ;;
    en:owned_wrapper_not_found) format='The Windows Steam app created by this setup app was not found' ;;
    en:unsafe_html_cache) format='Stopped because the Steam cache path points outside the Wine environment' ;;
    en:login_repaired) format='The login screen was repaired and Steam reopened' ;;
    en:checking_requirements) format='Checking whether this Mac meets the requirements' ;;
    en:apple_silicon_required) format='An Apple Silicon Mac is required' ;;
    en:macos_14_required) format='macOS Sonoma 14 or later is required' ;;
    en:installing_rosetta) format='Installing Apple Rosetta 2 for Windows app compatibility' ;;
    en:rosetta_install_failed) format='Could not install Rosetta 2 automatically' ;;
    en:rosetta_verify_failed) format='Could not verify the Rosetta 2 installation' ;;
    en:disk_space_required) format='Not enough storage space. Free at least 5 GB and try again' ;;
    en:downloading_components) format='Downloading components…' ;;
    en:setup_steam_first) format='Set up Steam first, on the Home screen.' ;;
    en:unsafe_download_path) format='The download path is unsafe: %s' ;;
    en:download_failed) format='Download failed: %s' ;;
    en:not_enough_space_download) format='Not enough disk space to download %s. Free some space and try again' ;;
    en:download_validation_failed) format='Downloaded-file validation failed: %s' ;;
    en:pinned_download_mismatch) format='The downloaded file does not match the pinned version: %s' ;;
    en:cached_download_mismatch) format='The cached file does not match the verified pinned version: %s' ;;
    en:runtime_engine) format='Runtime engine' ;;
    en:app_template) format='App template' ;;
    en:creating_wrapper) format='Creating the Mac app for Windows Steam' ;;
    en:unsafe_wrapper_path) format='Cannot continue safely because the Steam.app path is a symbolic link' ;;
    en:unowned_wrapper) format='The existing Steam.app was not created by this setup app and was left unchanged' ;;
    en:wrapper_create_failed) format='Could not safely create the Windows Steam app' ;;
    en:generated_launcher_missing) format='The generated Sikarugir launcher was not found' ;;
    en:preparing_windows) format='Preparing the Windows environment for the first time' ;;
    en:windows_environment_failed) format='Could not create the Windows environment' ;;
    en:steam_installer_instruction) format='In the Steam installer, keep the default options and click through.' ;;
    en:unsafe_steam_setup_symlink) format='Stopped because the Steam installer path is a symbolic link' ;;
    en:unsafe_steam_setup_directory) format='Stopped because the Steam installer path is a directory' ;;
    en:steam_setup_validation_failed) format='The newly downloaded Steam installer failed validation' ;;
    en:steam_install_confirmed) format='Steam installation detected. Cleaning up the first launch and applying final settings' ;;
    en:steam_install_timeout) format='Timed out while waiting for the Steam installation' ;;
    en:steam_install_failed) format='Setup did not finish. Click Try Again.' ;;
    en:applying_configuration) format='Applying D3DMetal and launch settings' ;;
    en:steam_plist_missing) format='The Steam app configuration file was not found' ;;
    en:d3dmetal_verify_failed) format='Could not verify the D3DMetal configuration' ;;
    en:ready_to_launch) format='Setup is complete. Starting Windows Steam' ;;
    en:shortcut_steam_missing) format='Windows Steam is not installed' ;;
    en:shortcut_steam_start_failed) format='Could not start Windows Steam' ;;
    en:shortcut_game_start_failed) format='Could not start the game in Windows Steam' ;;
    *) format="$key" ;;
  esac

  printf "$format" "$@"
}
