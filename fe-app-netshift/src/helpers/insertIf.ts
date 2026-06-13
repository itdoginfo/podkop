export function insertIf<T>(condition: boolean, elements: Array<T>) {
  return condition ? elements : ([] as Array<T>);
}

export function insertIfObj<T>(condition: boolean, object: T) {
  return condition ? object : ({} as T);
}
