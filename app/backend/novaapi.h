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

public:
    explicit NovaApi(QObject* parent = nullptr);
    // el motor de la interfaz (para convertir las respuestas en objetos de QML)
    void setEngine(QJSEngine* engine) { m_Engine = engine; }

    bool loggedIn() const { return !m_Session.isEmpty(); }
    QString firstName() const { return m_FirstName; }
    QString email() const { return m_Email; }

    // callback(ok, twoFactorRequired, message)
    Q_INVOKABLE void login(QString email, QString password, QJSValue callback);
    // callback(ok, false, message)
    Q_INVOKABLE void loginTwoFactor(QString code, QJSValue callback);
    Q_INVOKABLE void logout();
    // callback(status, body): body es el JSON ya convertido (objeto o lista) o null
    Q_INVOKABLE void get(QString path, QJSValue callback);
    Q_INVOKABLE void post(QString path, QVariant body, QJSValue callback);

signals:
    void sessionChanged();
    // la sesion vencio o se cerro desde otro lado: la app vuelve a pedir el inicio de sesion
    void sessionExpired();

private:
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
    QJSEngine* m_Engine = nullptr;
};
