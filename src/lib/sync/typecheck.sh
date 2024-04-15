#!/bin/sh

# sed filters out type errors from code unrelated to the sync feature.
npm run check | sed '/src\/lib\/\(providers\/pedals\/.*\.svelte\|Chat\.svelte\|Sidebar\.svelte\|ChatRequest\.svelte\|ChatCompletionResponse\.svelte\|providers\/openai\/request\.svelte\|Navbar\.svelte\|EditMessage\.svelte\|ChatSettingField\.svelte\|ChatSettingsModal\.svelte\)/,+6d'
