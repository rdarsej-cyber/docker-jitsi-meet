// Custom overrides — appended after template config on container restart
// DO NOT override sourceNameSignaling — this version requires it true

// Enable simulcast — template has it disabled which breaks pinning/switching
config.disableSimulcast = false;

// Receive all video streams, no limit
config.channelLastN = -1;

// Keep all video layers active (prevents black screen on pin)
config.enableLayerSuspension = false;

// Lock display names from JWT
config.disableProfile = true;

// Disable stage filmstrip for classic pin behavior
config.filmstrip = config.filmstrip || {};
config.filmstrip.disableStageFilmstrip = true;

// Tile view — dynamic space usage
config.tileView = { numberOfVisibleTiles: 25 };
config.disableTileEnlargement = false;
