# Haxe Fabric Glue
A macro library that automagically generates mixin "glue" that connects to haxe mixin definitions

## Caveats

The real "mixin" library is in the `glue` submodule, relative to where the mixin definition is. Thus, in your jsons, you must add `.glue` to the end of the `package`. A way to get around this would be to swap the positioning but that sounds like an absolute nightmare. 

## Usage

