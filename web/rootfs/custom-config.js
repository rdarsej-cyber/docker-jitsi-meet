// Custom overrides — appended after template config on container restart

// Enable simulcast for proper pinning and video quality switching
config.disableSimulcast = false;

// Receive all video streams, no limit
config.channelLastN = -1;

// Keep all video layers active (prevents black screen on pin)
config.enableLayerSuspension = false;

// Lock display names from JWT
config.disableProfile = true;

// Tile view — dynamic space usage
config.tileView = { numberOfVisibleTiles: 25 };
config.disableTileEnlargement = false;
