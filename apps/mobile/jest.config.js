module.exports = {
  preset: '@react-native/jest-preset',
  setupFiles: ['<rootDir>/jest.setup.js'],
  moduleNameMapper: {
    '\\.(tflite)$': '<rootDir>/jest.tflite.mock.js',
  },
};
