#pragma once

// Nova Play: menu flotante «Ajustes de la transmision» (como el de Parsec), dibujado con SDL encima del video.
// Mientras se transmite, Qt esta detenido (Session::exec acapara el hilo), asi que el menu NO puede ser una ventana de Qt:
// se dibuja en una superficie propia que el OverlayManager muestra en el lugar del overlay de estadisticas (arriba a la izquierda).
//   - Boton «N»: sale 8 s al empezar y cuando el raton (libre) se acerca a la esquina de arriba a la izquierda.
//   - Se abre con el boton, con Ctrl+Alt+Shift+N o con Select+Start mantenidos 1 s.
//   - Video (resolucion, FPS, bitrate, codec, V-Sync) se aplica con «Aplicar y reconectar» (la transmision se reinicia sola
//     contra la misma consola; el juego sigue abierto). Pantalla, sonido, raton y estadisticas cambian al instante.

#include "SDL_compat.h"
#include <SDL_ttf.h>

#include <QString>
#include <QStringList>
#include <QVector>

class Session;

class NovaMenu
{
public:
    explicit NovaMenu(Session* session);
    ~NovaMenu();

    // true si el evento fue para el menu (no se manda a la consola)
    bool handleEvent(const SDL_Event& event);
    // cada 250 ms: combinacion del mando, ocultar el boton, redibujar tras cambiar de pantalla completa
    void tick();
    void toggle();
    bool isOpen() const { return m_Open; }

private:
    enum Kind { Header, Choice, Slider, Toggle, Info, Action };
    enum Id {
        IdResolution, IdFps, IdBitrate, IdCodec, IdVsync, IdWindow, IdNetwork,
        IdAudioDevice, IdVolume, IdMute,
        IdGamepads, IdMouseMode, IdCapture,
        IdStats, IdKeys,
        IdApply, IdClose, IdNone
    };
    struct Row {
        Kind kind;
        Id id;
        QString label;
        QStringList options;   // Choice
        int index = 0;         // Choice / Toggle (0/1)
        int min = 0, max = 0, step = 1, value = 0;   // Slider
        bool reconnect = false;
        QString hint;
        SDL_Rect rect = {0, 0, 0, 0};   // en pixeles de la superficie (para el raton)
    };

    void open();
    void close();
    void build();
    void render();
    void renderButton();
    void clearOverlay();
    void change(Row& row, int delta);
    void activate(Row& row);
    void moveSelection(int delta);
    bool pendingReconnect() const;
    void applyAndReconnect();
    Row* rowById(Id id);
    int hitRow(int x, int y) const;
    void toSurface(int wx, int wy, int& sx, int& sy) const;
    float scale() const;
    TTF_Font* font(int px, bool bold);

    Session* m_Session;
    QVector<Row> m_Rows;
    int m_Selected = 0;
    bool m_Open = false;
    bool m_Reconnecting = false;
    bool m_CaptureOnClose = true;
    bool m_ButtonVisible = false;
    Uint32 m_ButtonUntil = 0;
    SDL_Rect m_ButtonRect = {0, 0, 0, 0};
    int m_RedrawTicks = 0;
    int m_StartWidth = 0, m_StartHeight = 0, m_StartFps = 0, m_StartBitrate = 0, m_StartCodec = 0;
    bool m_StartVsync = false;
    QByteArray m_FontData;
    struct CachedFont { int px; bool bold; TTF_Font* font; };
    QVector<CachedFont> m_Fonts;
    QString m_Status;
};
