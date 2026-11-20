-- CharacterOutfitAppearancePlanner (server path): forwards to src/shared/CharacterOutfitAppearancePlanner.luau.
--
-- The planner's rules (development spec §3.7) moved to src/shared so that the device's wardrobe
-- preview dresses its copy with exactly the rules the server uses, without a second copy of them.
-- This file is kept so that existing server requires (PlayerCharacterDresser) and tests keep their
-- path; whether to remove it is for the project owner to decide. It holds no logic of its own and
-- returns the very same module table as the shared file.

return require("../shared/CharacterOutfitAppearancePlanner")
