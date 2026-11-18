#pragma once

#include <QString>

#include "SDL_compat.h"
#include <SDL_ttf.h>

namespace Overlay {

enum OverlayType {
    OverlayDebug,
    OverlayStatusUpdate,
    OverlayMax
};

class IOverlayRenderer
{
public:
    virtual ~IOverlayRenderer() = default;

    virtual void notifyOverlayUpdated(OverlayType type) = 0;
};

class OverlayManager
{
public:
    OverlayManager();
    ~OverlayManager();

    bool isOverlayEnabled(OverlayType type);
    char* getOverlayText(OverlayType type);
    void updateOverlayText(OverlayType type, const char* text);
    int getOverlayMaxTextLength();
    void setOverlayTextUpdated(OverlayType type);
    void setOverlayState(OverlayType type, bool enabled);
    SDL_Color getOverlayColor(OverlayType type);
    int getOverlayFontSize(OverlayType type);
    SDL_Surface* getUpdatedOverlaySurface(OverlayType type);

    void setOverlayRenderer(IOverlayRenderer* renderer);

    // Nova Play: imagen propia (menu de ajustes, boton «N») en lugar del texto del overlay. La superficie pasa a ser del
    // OverlayManager; nullptr vuelve al texto normal (las estadisticas).
    void setOverlayCustomSurface(OverlayType type, SDL_Surface* surface);
    bool hasOverlayCustomSurface(OverlayType type) { return m_Custom[type]; }
    // estado que tendra el overlay de texto cuando se quite la imagen propia
    void setOverlayEnabledAfterCustom(OverlayType type, bool enabled) { if (m_Custom[type]) m_EnabledBeforeCustom[type] = enabled; else setOverlayState(type, enabled); }
    bool overlayEnabledAfterCustom(OverlayType type) { return m_Custom[type] ? m_EnabledBeforeCustom[type] : m_Overlays[type].enabled; }
    const QByteArray& fontData() { return m_FontData; }

private:
    void notifyOverlayUpdated(OverlayType type);
    SDL_Surface* RenderTextOutlinedWrapped(TTF_Font* font, const char* text, SDL_Color textColor, SDL_Color outlineColor, int outlineWidth, int wrapWidth);

    struct {
        bool enabled;
        int fontSize;
        SDL_Color color;
        char text[1024];

        TTF_Font* font;
        SDL_Surface* surface;
    } m_Overlays[OverlayMax];
    IOverlayRenderer* m_Renderer;
    bool m_Custom[OverlayMax] = {};
    bool m_EnabledBeforeCustom[OverlayMax] = {};
    QByteArray m_FontData;
};

}
