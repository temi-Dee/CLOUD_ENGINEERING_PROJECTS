const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
const secretsManager = new SecretsManagerClient({});

let cachedSecret = null;
let cacheExpiry = 0;

async function getSecret(secretName) {
  if (cachedSecret && Date.now() < cacheExpiry) {
    return cachedSecret;
  }

  const result = await secretsManager.send(new GetSecretValueCommand({ SecretId: secretName }));
  cachedSecret = JSON.parse(result.SecretString);
  cacheExpiry = Date.now() + 5 * 60 * 1000;
  return cachedSecret;
}

exports.handler = async (event) => {
  const dbSecrets = await getSecret('prod/database/credentials');
  return {
    statusCode: 200,
    body: JSON.stringify({
      message: 'Loaded secrets successfully',
      dbUser: dbSecrets.username
    })
  };
};
