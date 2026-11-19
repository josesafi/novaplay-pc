#pragma once

#include <functional>

#include <QObject>
#include <QJSValue>
#include <QNetworkAccessManager>
#include <QVariant>

class QNetworkReply;
class QJSEngine;

// Nova Play: conexion con la cuenta de novawebcolombia.com (la misma API que usa el panel).
// Inicia sesion con correo y contrasena (y el codigo de verificacion en dos pasos si la cuenta lo tiene), guarda la sesion
// en las preferencias del usuario de Windows y hace las llamadas con la cookie de sesion y la cabecera X-CSRF-Token.
class NovaApi : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool loggedIn READ loggedIn NOTIFY sessionChanged)
    Q_PROPERTY(QString firstName READ firstName NOTIFY sessionChanged)
    Q_PROPERTY(QString email READ email NOTIFY sessionChanged)
    Q_PROPERTY(bool twoFactorEnabled READ twoFactorEnabled NOTIFY sessionChanged)
    // recordar el correo y la contrasena en este PC (la contrasena va al Administrador de credenciales de Windows, cifrada por Windows)
    Q_PROPERTY(bool rememberEmail READ rememberEmail WRITE setRememberEmail NOTIFY rememberChanged)
    Q_PROPERTY(bool rememberPassword READ rememberPassword WRITE setRememberPassword NOTIFY rememberChanged)
    Q_PROPERTY(bool canRememberPassword READ canRememberPassword CONSTANT)
    Q_PROPERTY(QString savedEmail READ savedEmail NOTIFY rememberChanged)

public:
    explicit NovaApi(QObject* parent = nullptr);
    // el motor de la interfaz (para convertir las respuestas en objetos de QML)
    void setEngine(QJSEngine* engine) { m_Engine = engine; }

    bool loggedIn() const { return !m_Session.isEmpty(); }
    QString firstName() const { return m_FirstName; }
    QString email() const { return m_Email; }
    bool twoFactorEnabled() const { return m_TwoFactorEnabled; }
    bool rememberEmail() const;
    void setRememberEmail(bool on);
    bool rememberPassword() const;
    void setRememberPassword(bool on);
    bool canRememberPassword() const;
    QString savedEmail() const;

    // contrasena guardada para ese correo (vacio si no hay); se guarda sola al iniciar sesion si rememberPassword esta activo
    Q_INVOKABLE QString savedPassword(QString email) const;
    Q_INVOKABLE void forgetSavedPassword();
    // llamadas SIN sesion (crear cuenta, recuperar contrasena, pregunta antibot): callback(status, body)
    Q_INVOKABLE void publicGet(QString path, QJSValue callback);
    Q_INVOKABLE void publicPost(QString path, QVariant body, QJSValue callback);
    // vuelve a leer la sesion (p. ej. tras activar el autenticador)
    Q_INVOKABLE void refreshSession();
    // QR de un texto (otpauth://…): {size, modules: [bool…]} fila por fila
    Q_INVOKABLE QVariantMap qrCode(QString text) const;
    Q_INVOKABLE void copyText(QString text) const;
    // mensaje claro de un error de la API (lo mismo que usa el inicio de sesion)
    Q_INVOKABLE QString describeError(int status, QVariant body) const { return errorMessage(status, body); }

    // callback(ok, twoFactorRequired, message)
    Q_INVOKABLE void login(QString email, QString password, QJSValue callback);
    // callback(ok, false, message)
    Q_INVOKABLE void loginTwoFactor(QString code, QJSValue callback);
    Q_INVOKABLE void logout();
    // callback(status, body): body es el JSON ya convertido (objeto o lista) o null
    Q_INVOKABLE void get(QString path, QJSValue callback);
    Q_INVOKABLE void post(QString path, QVariant body, QJSValue callback);
    // cuenta con la que se juega (la fija el inicio); la usa «Cerrar el juego» del panel «N» durante la transmision
    Q_INVOKABLE void setPlayAccount(QString accountId) { m_PlayAccount = accountId; }

    // «Cerrar el juego» (juego congelado): POST play/close-game en un hilo propio, porque mientras se transmite el bucle de Qt esta
    // detenido. done(status) se llama DESDE ESE HILO (0 = sin red, sin sesion o sin cuenta).
    static void closeGameAsync(std::function<void(int status)> done);

signals:
    void sessionChanged();
    // la sesion vencio o se cerro desde otro lado: la app vuelve a pedir el inicio de sesion
    void sessionExpired();
    void rememberChanged();

private:
    void storePassword(const QString& email, const QString& password);
    void deletePassword(const QString& email);
    using Done = std::function<void(int status, const QVariant& body)>;
    void send(const QByteArray& method, const QString& path, const QVariant& body, bool authed, Done done);
    void callJs(QJSValue callback, const QJSValueList& args);
    void finishLogin(const QVariant& body, QJSValue callback);
    void takeSessionCookie(QNetworkReply* reply);
    static QString errorMessage(int status, const QVariant& body);
    void loadSession();
    void saveSession();

    QNetworkAccessManager m_Nam;
    QString m_Session;
    QString m_Csrf;
    QString m_FirstName;
    QString m_Email;
    QString m_Challenge;
    QString m_PendingPassword;
    bool m_TwoFactorEnabled = false;
    QJSEngine* m_Engine = nullptr;
    QString m_PlayAccount;
    static NovaApi* s_Instance;
};
