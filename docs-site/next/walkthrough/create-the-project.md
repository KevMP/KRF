---
title: Create a KRF project
sidebar_label: 0. Create a KRF project
sidebar_position: 1
description: Use the KRF template generator to create a project and run it in Studio.
---

# Create a KRF project

You'll need Node.js 22.12 or later and Roblox Studio.

## Generate the project

```bash
npm create krf@latest my-game
```

Choose Full when the template generator asks for a project mode. Rojo will build the whole place from your project files. The GitHub Actions workflow is optional.

The generated project includes setup scripts for tools such as Rojo and packages from Wally. Install them with:

```bash
cd my-game
npm install
```

## Run the game

```bash
npm run dev
```

The command will open `my-game.rbxl` in Studio and start Rojo. Open the Rojo plugin and click Connect. Keep the terminal running so Rojo can sync your code changes to Studio.

If the Rojo plugin is missing, run `rojo plugin install` from the project folder and restart Studio.

Press Play. You should see `Energy 0/100` in the bottom-left corner. Hold F to increase Energy, then release F to stop.

## Next

In [Gather Qi](./gather-qi), you'll replace the starter's Energy meter with Qi.
