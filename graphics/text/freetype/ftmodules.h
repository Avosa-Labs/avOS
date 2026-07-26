/*
 * The FreeType modules avOS compiles in, replacing the upstream default list.
 *
 * FreeType's default `ftmodule.h` registers every driver it ships — Type 1, CID,
 * PFR, Type 42, Windows FNT, PCF, BDF, SVG — and registering a driver requires
 * linking its code. This list is the subset the text path needs: the autohinter,
 * the TrueType and CFF outline drivers, the PostScript helpers those depend on,
 * the SFNT wrapper, and the anti-aliased and monochrome renderers. It is selected
 * with `-DFT_CONFIG_MODULES_H=<ftmodules.h>` so the build links exactly these.
 */

FT_USE_MODULE( FT_Module_Class, autofit_module_class )
FT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )
FT_USE_MODULE( FT_Driver_ClassRec, cff_driver_class )
FT_USE_MODULE( FT_Module_Class, psaux_module_class )
FT_USE_MODULE( FT_Module_Class, psnames_module_class )
FT_USE_MODULE( FT_Module_Class, pshinter_module_class )
FT_USE_MODULE( FT_Module_Class, sfnt_module_class )
FT_USE_MODULE( FT_Renderer_Class, ft_smooth_renderer_class )
FT_USE_MODULE( FT_Renderer_Class, ft_raster1_renderer_class )

/* EOF */
